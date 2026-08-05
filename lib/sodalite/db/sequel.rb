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
    class Sequel
      include SequelDDL
      include SequelArrows
      include Ledger

      LEDGER = :sodalite_migrations
      MIGRATION_LOCK = :sodalite_migration_lock

      attr_reader :schema

      def initialize(schema, database)
        @schema = schema.is_a?(History) ? schema.schema : schema
        @db = database
      end

      def create_tables!
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

      def claim_lock(token)
        ensure_lock!
        # Sequel, rather than handwritten SQL, owns the backend's dialect here.
        @db[MIGRATION_LOCK].insert(id: 1, token: token)
        true
      rescue ::Sequel::UniqueConstraintViolation
        false
      end

      def release_lock(token)
        ensure_lock!
        @db[MIGRATION_LOCK].where(id: 1, token: token).delete
        nil
      end

      private

      def ensure_ledger!
        return if @db.table_exists?(LEDGER)

        @db.create_table(LEDGER) do
          String :fingerprint, primary_key: true
          String :step
        end
      end

      def ensure_lock!
        return if @db.table_exists?(MIGRATION_LOCK)

        @db.create_table(MIGRATION_LOCK) do
          Integer :id, primary_key: true
          String :token
        end
      end
    end
  end
end
