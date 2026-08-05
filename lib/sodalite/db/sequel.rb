# frozen_string_literal: true

module Sodalite
  module DB
    # A third model, lowered onto Sequel's dataset algebra instead of onto SQL
    # text.
    #
    # This is not "use Sequel instead". The arrows are the theory — a schema is a
    # category, a query is a morphism in the regular fragment — and Sequel is a
    # backend: dialects, identifier quoting, connection pooling, type conversion.
    # Different layers, so the right move is to lower onto its expression API and
    # leave the meaning of an arrow untouched. Sequel's own `Dataset` chaining is
    # a second query language and is deliberately not exposed; what is used here
    # is the part that knows how to *spell* things for a given database.
    #
    # What that buys over `DB::Sql`, measured rather than assumed: identifiers
    # are quoted (a table called `order` works), `OFFSET` without `LIMIT` is
    # spelled per dialect rather than as SQLite's `LIMIT -1`, and placeholders are
    # the driver's rather than a hard-coded `?`.
    #
    # `DB::Sql` is kept, not replaced. Three models checked against each other is
    # a stronger claim than two, and the hand-written one is the only one that
    # shows what the compilation actually is.
    #
    # Sequel stays out of the runtime dependencies: this takes a `Sequel::Database`
    # someone else built, the same way `DB::Sql` takes anything with `execute`.
    class Sequel # rubocop:disable Metrics/ClassLength
      include SequelDDL
      include SequelArrows
      include Ledger

      LEDGER = :sodalite_migrations
      MIGRATION_LOCK = :sodalite_migration_lock

      # Sequel answers whether DDL survives a rollback for itself, which is the
      # whole point of lowering onto a backend that knows dialects — but its
      # answer is a *lower* bound. `supports_transactional_ddl?` is `false` by
      # default and only mssql, postgres, and derby override it, so sqlite —
      # which has had transactional DDL for as long as it has had transactions —
      # reports that it has none (measured against sequel 5.107, not assumed).
      # Believing that default would refuse every sqlite migration, so where
      # Sequel is silent the adapter's own name is consulted.
      TRANSACTIONAL_DDL_ADAPTERS = %i[sqlite].freeze

      attr_reader :schema

      def initialize(schema, database)
        @schema = schema.is_a?(History) ? schema.schema : schema
        @db = database
      end

      # The whole schema in one shot, with **no ledger behind it** — which is
      # what the name says and why it says it. `verify!` reads the ledger and
      # nothing else, so a database built this way is refused at boot with
      # "database is missing required migrations". Anything that boots against
      # `verify!` goes through `migrate!` instead; this is for a suite that
      # wants a shape and has no history to get it from.
      def create_tables_for_test!
        @schema.tables.each_value { |table| create_table(table) }
        self
      end

      # --- the functor laws, checkable ---------------------------------------
      # A dangling foreign key is not a bad row. It is a failure to be a functor:
      # the morphism `posts -> users` has no value at that element. The in-memory
      # model answers this by intersecting sets; here it is two datasets, and the
      # sentence is the schema's either way so the three models cannot report the
      # same failure in three wordings.
      #
      # It stays a diagnostic. Nothing calls it on `insert` or `delete` and the DDL
      # emits no `REFERENCES`, because integrity here is a property of the instance
      # that can be asked about, not a constraint the backend is told to hold.
      def functor?
        violations.empty?
      end

      def violations
        @schema.tables.each_value.flat_map do |table|
          table.foreign_keys.flat_map { |field, target| dangling(table, field, target) }
        end
      end

      # `NOT IN` over a null is `UNKNOWN`, so a row where the morphism has no value
      # at all would fall out of both sides of it and be reported by neither. That
      # row is exactly the one being looked for, so it is asked for explicitly
      # rather than left to three-valued logic — which is also what makes this
      # agree with the model that computes it in Set.
      def dangling(table, field, target)
        keys = @db[target].select(@schema.table(target).key)
        @db[table.name].exclude(field => keys).or(field => nil).select_map(field)
                       .map { |value| @schema.dangling_message(table.name, field, value, target) }
      end

      # --- reading ------------------------------------------------------------

      def select(query)
        rows = dataset(query).all.map { |row| row.transform_keys(&:to_sym) }
        return Listing[rows, schema: query.row_schema] if query.ordered?

        Relation[rows, schema: query.row_schema]
      end

      def insert(table_name, row)
        table = @schema.table(table_name)
        typed = table.row_schema.load(row.to_h { |field, value| [field.to_s, value] })
        raise SchemaError, "#{table_name}: #{typed.violations.join('; ')}" unless typed.ok?

        @db[table.name].insert(table.fields.to_h { |field| [field, row[field]] })
        row[table.key]
      end

      # Naming the doomed rows by their keys needs the keys to be there, which is
      # `deletable!`'s job: a projection has dropped them, and `where(key => [nil,
      # nil])` then deletes nothing while the count says otherwise. So the arrow is
      # checked before anything runs, and the count is the one the backend reports
      # rather than the size of a set measured a statement earlier — between the
      # two, another writer is a possibility, and the honest number is the one the
      # `DELETE` actually did.
      #
      # Reading the keys and deleting by them are two statements, so they are one
      # scope. `atomically` joins an outer transaction rather than opening a
      # second, which is what makes that safe to say here.
      def delete(query, confirm_carrier: nil)
        query.deletable!(confirm_carrier: confirm_carrier)
        table = @schema.table(query.carrier)
        atomically do
          keys = select(query).rows.map { |row| row[table.key] }
          # An empty subobject is not a `DELETE` with an empty list; it is nothing
          # to do.
          next 0 if keys.empty?

          @db[table.name].where(table.key => keys).delete
        end
      end

      # Same contract as the other two: the caller never asks for a rollback, it
      # is what `Err` means to the scope. `Sequel::Rollback` is how Sequel spells
      # "unwind without raising past me".
      #
      # A nested scope joins the outermost one, which is what `Memory#atomically`
      # spells out and what `Sequel::Database#transaction` already does by
      # default — so the depth counter is Sequel's own, asked for by name. What
      # Sequel does *not* do is scope the rollback: a `Sequel::Rollback` raised
      # inside a joined block is not caught by that block's own `transaction`
      # call, it escapes to the outermost one, taking the inner scope's result
      # with it. So an inner scope does not raise at all. It returns its `Err`
      # and lets the outermost scope decide, which is also how the other two
      # models read it.
      def atomically
        outermost = !@db.in_transaction?
        result = nil
        @db.transaction do
          result = yield
          raise ::Sequel::Rollback if outermost && result.is_a?(Berylx::Err)
        end
        result
      end

      # --- migration ----------------------------------------------------------

      def read_ledger
        ensure_ledger!
        @db[LEDGER].select_hash(:fingerprint, :step)
      end

      def record_step(step)
        ensure_ledger!
        @db[LEDGER].insert(fingerprint: step.fingerprint, step: step.to_s)
        nil
      end

      def forget_step(step)
        ensure_ledger!
        @db[LEDGER].where(fingerprint: step.fingerprint).delete
        nil
      end

      def transactional_ddl?
        @db.supports_transactional_ddl? || TRANSACTIONAL_DDL_ADAPTERS.include?(@db.adapter_scheme)
      end

      # `Sequel::Database#transaction` already joins an outer transaction rather
      # than opening a second, so composing with `atomically` costs nothing
      # here, and a raise inside unwinds it. What it does not do is unwind on a
      # result, which is right: a migration block has no result to speak of.
      def migration_scope
        result = nil
        @db.transaction { result = yield }
        result
      end

      # Two readings, taken before anything is carried. The sentences are
      # `Preflight`'s, so this model and the other two refuse a step in one
      # wording rather than three.
      def preflight_violations(step)
        table, *rest = step.args
        case step.kind
        when :split_table then unlisted_tags(table, rest[0], rest[1], distinct_values(table, rest[0]))
        when :merge_tables then colliding_keys(key_of(rest[0]), key_holders(table, rest[0]))
        else []
        end
      end

      # The insert is the claim, and `id` is a primary key, so two runners
      # racing here are settled by the database. Sequel maps the driver's
      # uniqueness error onto a class of its own, so the lost race is caught by
      # name — which the `Sql` model cannot do, because its port is
      # `execute(sql, binds) -> rows` and the error class is whatever the driver
      # chose. The row still decides, for the same reason it decides there:
      # whoever's token is in it won.
      def claim_lock(token) # rubocop:disable Naming/PredicateMethod
        ensure_lock!
        begin
          @db[MIGRATION_LOCK].insert(id: 1, token: token, holder: lock_holder,
                                     acquired_at: lock_acquired_at)
        rescue ::Sequel::UniqueConstraintViolation
          nil
        end
        read_lock&.fetch(:token) == token
      end

      def read_lock
        ensure_lock!
        held = @db[MIGRATION_LOCK].where(id: 1).first
        held && { token: held[:token], holder: held[:holder], acquired_at: held[:acquired_at] }
      end

      def release_lock(token)
        ensure_lock!
        @db[MIGRATION_LOCK].where(id: 1, token: token).delete
        nil
      end

      private

      def distinct_values(table, field)
        @db[table].distinct.select_map(field)
      end

      def key_holders(sources, into)
        key = key_of(into)
        sources.each_with_object(Hash.new { |all, value| all[value] = [] }) do |source, holders|
          @db[source].select_map(key).each { |value| holders[value] << source }
        end
      end

      # The sources of a coproduct share a shape, so they share the key the
      # target has — and the target is the one of them the schema still knows
      # about once the step has been applied to the presentation.
      def key_of(into)
        @schema.table(into).key
      end

      def ensure_ledger!
        return if @db.table_exists?(LEDGER)

        @db.create_table(LEDGER) do
          String :fingerprint, primary_key: true
          String :step
        end
      end

      # A table an older version of this file created has neither `holder` nor
      # `acquired_at`, and is left alone rather than widened. Sequel reads the
      # row by name, so both come back `nil` and the lock reads as one of
      # unknown age — which `steal_lock!` is allowed to clear. The hand-written
      # model names its columns in one `SELECT` and is less forgiving; it says
      # so next door.
      def ensure_lock!
        return if @db.table_exists?(MIGRATION_LOCK)

        @db.create_table(MIGRATION_LOCK) do
          Integer :id, primary_key: true
          String :token
          String :holder
          String :acquired_at
        end
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
