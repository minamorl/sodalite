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

      # --- the path equations, checkable --------------------------------------
      # A dangling key is a failure to be a functor; a path equation is a
      # condition on the functor once it is one, and it is the one SQL cannot
      # hold — a foreign key relates a column to a key, never a path to a path.
      # So it is declared in the presentation, and asked about here.
      #
      # Reported, not enforced, exactly as `functor?` is, and an element with no
      # image on either side is not reported: the join has no row for it, or the
      # comparison is over a NULL and is UNKNOWN. The model that walks rows in
      # Set is brought to that same reading rather than the other way round, so
      # the three agree about which elements the equation has anything to say
      # about.
      def satisfies_equations?
        equation_violations.empty?
      end

      def equation_violations
        @schema.equations.flat_map { |equation| unequal(equation) }
      end

      # The two columns are aliased before they are read back. Both sides of an
      # equation usually end in the *same* morphism name — that is what makes it
      # an equation worth declaring — so a row keyed by column name would hand
      # back one value twice.
      def unequal(equation)
        rows, columns = equation_dataset(equation)
        key = column(:t0, @schema.table(equation.from).key)
        rows.select_map([key.as(:element), columns.first.as(:one), columns.last.as(:other)])
            .map { |element, one, other| @schema.equation_message(equation, element, one, other) }
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

      # One statement, with the guard inside it, which is the whole reason this
      # operation exists. Reading a row and writing it back is atomic without
      # being serialisable — under READ COMMITTED two scopes both read `stock =
      # 1` and both write `0` — and what removes that is writing the new value as
      # a function of the old one. So `:add` lowers to an expression the database
      # computes and never to a value read into Ruby, and the engine applies it
      # under its own row lock to whatever the value is by then. A negative delta
      # is the decrement.
      #
      # The count is the one the `UPDATE` reports, for the same reason `delete`'s
      # is: a count taken beforehand is the size of a set another writer may have
      # moved since.
      def update(query, changes, confirm_carrier: nil)
        query.updatable!(changes, confirm_carrier: confirm_carrier)
        guarded(query).update(assignments(changes))
      end

      # A deletion names rows of the carrier, so the arrow has to be a subobject
      # of them — `deletable!`'s job, and it is asked before anything runs.
      #
      # The guard goes inside the `DELETE`, so there is no select before it and
      # no scope holding two statements together, and the count is the one the
      # statement reports rather than the size of a set measured before it: in
      # between, another writer is a possibility, and the honest number is the
      # one the `DELETE` did. That last part is what a real driver buys. The
      # hand-written model reaches its database through `execute(sql, binds) ->
      # rows`, which cannot say how many rows a statement affected, so it needs a
      # widened port before it can have this shape at all — the difference
      # between a backend and a one-method port, in one sentence.
      def delete(query, confirm_carrier: nil)
        query.deletable!(confirm_carrier: confirm_carrier)
        guarded(query).delete
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

      # Both sides of one equation in one dataset. Their aliases come from a
      # single supply, or the second side's joins would name the rows the first
      # side's already named and both columns would be read off the same row.
      #
      # `exclude` is `NOT (a = b)`, which over a NULL is UNKNOWN and drops the
      # row — the same three-valued reading `<>` gives the hand-written model,
      # and the same set the in-memory one computes by refusing to compare an
      # undefined composite.
      def equation_dataset(equation)
        from = equation.from
        left = hops_along(from, equation.left, 1)
        right = hops_along(from, equation.right, 1 + left.size)
        columns = [side_column(from, equation.left, left), side_column(from, equation.right, right)]
        [joined(from, left + right).exclude(columns.first => columns.last), columns]
      end

      # The source object, with every hop both sides take joined onto it.
      def joined(from, hops)
        hops.reduce(@db[::Sequel[from].as(:t0)]) { |dataset, hop| join_hop(dataset, hop) }
      end

      # The joins one side takes: a path of length n is n-1 of them, because the
      # last morphism is the column being compared rather than a row to reach.
      def hops_along(from, path, first)
        objects = @schema.path_objects(from, path)
        path[0..-2].each_with_index.map do |fk, hop|
          [objects[hop + 1], :"t#{first + hop}", hop.zero? ? :t0 : :"t#{first + hop - 1}", fk]
        end
      end

      # The column a composite ends at. An empty path is the identity, so it is
      # the source's own key.
      def side_column(from, path, hops)
        return column(:t0, @schema.table(from).key) if path.empty?

        column(hops.empty? ? :t0 : hops.last[1], path.last)
      end

      def join_hop(dataset, hop)
        target, name, source, fk = hop
        dataset.join(::Sequel[target].as(name), @schema.table(target).key => column(source, fk))
      end

      # The rows an arrow names, as a dataset over the carrier's own table — the
      # thing a `DELETE` or an `UPDATE` is issued against, guard included.
      #
      # An arrow that never joined is already a subobject of its carrier, so its
      # own steps are the guard, replayed against a nil alias: a statement over
      # one table has nothing to qualify against, and nil is how these two files
      # already spell an unqualified column. The steps go back through `step`
      # rather than through a second reading of them, so a comparison cannot mean
      # one thing in a `SELECT` and another in an `UPDATE`.
      #
      # A join took its guard somewhere else — at the domain for a composition,
      # along a path for a pullback — so there the rows are named by the image of
      # the arrow on the key. Still one statement, and the guard is still
      # evaluated when that statement runs rather than before it.
      def guarded(query)
        table = @schema.table(query.carrier)
        joined = query.steps.any? { |kind, _| %i[follow pullback].include?(kind) }
        return @db[table.name].where(table.key => dataset(query.select(table.key))) if joined

        query.steps.reduce(@db[table.name]) do |rows, (kind, *rest)|
          step(rows, [[table.name, nil]], kind, rest, query)
        end
      end

      # `Change.ordered` is the one reading of a changes Hash, so declaration
      # order is the order `SET` gets and the rule that a bare value means `:set`
      # is not spelled a second time here.
      #
      # A `:set` is its operand. An `:add` is the column plus its operand, which
      # is what makes the new value a function of the old one — and over a column
      # that is nothing it is `NULL + delta`, so the value stays nothing. That is
      # SQL's answer, arrived at by not asking for another one.
      def assignments(changes)
        Change.ordered(changes).to_h do |field, change|
          [field, change.kind == :add ? column(nil, field) + change.operand : change.operand]
        end
      end

      def distinct_values(table, field)
        @db[table].distinct.select_map(field)
      end

      def key_holders(sources, key)
        sources.each_with_object(Hash.new { |all, value| all[value] = [] }) do |source, holders|
          @db[source].select_map(key).each { |value| holders[value] << source }
        end
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
