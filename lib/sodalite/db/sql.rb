# frozen_string_literal: true

module Sodalite
  module DB
    # The other model. `compile` is pure — it turns an arrow into SQL text and
    # binds, with no driver anywhere near it — so the compilation is testable
    # without a database, and the database is reachable through a one-method
    # port rather than a dependency.
    #
    # This is where the claim gets its teeth: composition becomes `JOIN`, a
    # subobject becomes `WHERE`, and image factorization becomes `DISTINCT`. You
    # never wrote a join; you composed two morphisms and the compiler spelled it.
    #
    # Longer than the line-count cop allows, and left so on purpose: the three
    # phases and the statements a model runs are one compiler, and cutting it in
    # two would put the walk behind one name and its quoting behind another
    # without either half reading better.
    module SQL # rubocop:disable Metrics/ModuleLength
      # The image is taken in a subquery the fold reads its columns out of, so
      # the fold needs a name for it. One name, in one place, because the three
      # spellings of it have to agree letter for letter.
      GROUP_ALIAS = 'g'

      # Every dialect spells "no limit" differently, and two of them refuse each
      # other's spelling: `LIMIT -1` is SQLite's and Postgres rejects a negative
      # limit, `LIMIT ALL` is Postgres's and SQLite will not parse it, and a bare
      # `OFFSET` is Postgres's and SQLite will not parse that either — all three
      # measured against sqlite3 rather than assumed. The largest signed 64-bit
      # integer is the one bound both accept, and no relation has that many rows,
      # so it is a limit that does not limit.
      UNBOUNDED = 9_223_372_036_854_775_807

      module_function

      def compile(query)
        rows, binds = coproduct(query)
        [query.grouped? ? grouped(query, rows) : "#{rows}#{order_by(query)}#{window(query)}", binds]
      end

      # Every identifier the compiler emits goes through here, so a schema stays
      # free to name an object `order` or an attribute `select`. Values were
      # never the exposure — they are bound — but a reserved word interpolated
      # bare is broken SQL, and refusing the name would be the model deciding
      # what the schema is allowed to say.
      #
      # ANSI double quotes: SQLite and Postgres both read them as an identifier,
      # MySQL only under `ANSI_QUOTES`. An embedded quote is doubled, which is
      # how the standard escapes one.
      def quote(identifier)
        %("#{identifier.to_s.gsub('"', '""')}")
      end

      # Phase one, including the coproduct. SQL's `UNION` deduplicates, so it is
      # the coproduct followed by image factorization — set union, which is what
      # a `Relation` means.
      def coproduct(query)
        rows, binds = row_source(query)
        query.unions.each do |other|
          other_sql, other_binds = compile(other)
          rows = "#{rows} UNION #{other_sql}"
          binds.concat(other_binds)
        end
        [rows, binds]
      end

      # The accumulators a phase-one walk fills travel together, so they are one
      # value rather than four parameters passed in step.
      #
      # `carrier` is the object later steps qualify against, and it is
      # deliberately not `aliases.last`. A pullback joins a table without moving
      # the carrier; which side of the span the result is read from is the whole
      # difference between it and a composition, and this field is where that
      # difference lives.
      Clauses = Data.define(:aliases, :carrier, :joins, :wheres, :binds) do
        def self.for(query) = at(query.root)

        # A path equation is checked at an object rather than along an arrow, so
        # the walk starts from the object itself. The accumulators are the same
        # ones either way, because a join is a join.
        def self.at(object)
          root = [object, 't0']
          new(aliases: [root], carrier: root, joins: [], wheres: [], binds: [])
        end

        def alias_now = carrier[1]
        def root_alias = aliases.first[1]

        # A fresh alias per hop. Two pullbacks along the same path each take
        # their own: the joins are taken along functions, so a second copy names
        # the same row as the first and the two spellings agree — sharing them
        # would be an optimization, and an optimization is not what an alias is
        # for.
        def hop(table)
          "t#{aliases.size}".tap { |name| aliases << [table, name] }
        end
      end

      def row_source(query)
        clauses = walk(query)
        ["SELECT #{'DISTINCT ' if query.distinct?}#{qualified_fields(query, clauses).join(', ')} " \
         "#{source_clause(query, clauses)}", clauses.binds]
      end

      # Phase one as accumulators rather than as text. Three statements need the
      # walk and only one of them is a `SELECT`, so where it ends is a value.
      def walk(query)
        query.steps.reduce(Clauses.for(query)) do |clauses, (kind, *rest)|
          phase_one(query, kind, rest, clauses)
        end
      end

      # Where the rows come from and which of them are kept — everything a
      # `SELECT` has after its field list, and everything a guarded subquery has
      # after its key.
      def source_clause(query, clauses)
        "FROM #{quote(query.root)} #{quote(clauses.root_alias)}" \
          "#{clauses.joins.join}#{where_clause(clauses.wheres)}"
      end

      # Each step answers with the walk that follows it, because one of them
      # moves the carrier and the rest leave it where it was.
      def phase_one(query, kind, rest, clauses)
        case kind
        when :follow   then follow(query, clauses, rest)
        when :pullback then pullback(query, clauses, rest)
        when :where    then filter(clauses, clauses.alias_now, rest)
        when :null     then null(clauses, rest)
        else clauses
        end
      end

      # Composition. The carrier moves to the codomain of the morphism, so the
      # fields and the filters that come after are read off the joined table.
      def follow(query, clauses, step)
        fk, target = step
        clauses.with(carrier: join(query.schema, clauses, clauses.carrier, fk, target))
      end

      # The pullback `f*(S)`. It emits the join a composition emits and then
      # leaves the carrier where it was, so what comes back is a subobject of the
      # domain: "posts whose author lives in tokyo" answers with posts. A path of
      # length n is n hops, each one a morphism out of the object the last
      # arrived at.
      def pullback(query, clauses, step)
        paths, field, operand, operator = step
        far = paths.reduce(clauses.carrier) do |source, fk|
          join(query.schema, clauses, source, fk, query.schema.target_of(source[0], fk))
        end
        filter(clauses, far[1], [field, operand, operator])
      end

      # `JOIN target ON source.fk = target.key`, and the pair the target is
      # reached by. Composition, the pullback, and a path equation's side all
      # emit the same join; they differ only in what is read off it afterwards,
      # so it takes the schema rather than an arrow.
      def join(schema, clauses, source, fk, target)
        key = schema.table(target).key
        target_alias = clauses.hop(target)
        clauses.joins << " JOIN #{quote(target)} #{quote(target_alias)} " \
                         "ON #{qualify(source[1], fk)} = #{qualify(target_alias, key)}"
        [target, target_alias]
      end

      # Both composites of one path equation, and the elements where they
      # disagree, in one statement.
      #
      # A path of length n is n-1 joins and then a column read: the last
      # morphism is the value being compared, and the ones before it are how the
      # row carrying it is reached. The two sides draw aliases from one supply,
      # or the second would read its column off the rows the first joined.
      #
      # An element whose composite has no image on either side falls out on its
      # own, and that is deliberate rather than convenient: the join drops an
      # element whose morphism has no value, and `<>` over a NULL is UNKNOWN. It
      # is the reading the other two models are held to, and here it is free.
      def equation_statement(schema, equation)
        clauses = Clauses.at(equation.from)
        left = side(schema, clauses, equation, equation.left)
        right = side(schema, clauses, equation, equation.right)
        key = qualify(clauses.root_alias, schema.table(equation.from).key)
        "SELECT #{key}, #{left}, #{right} FROM #{quote(equation.from)} #{quote(clauses.root_alias)}" \
          "#{clauses.joins.join} WHERE #{left} <> #{right}"
      end

      # One side of an equation, as the column its composite ends at. An empty
      # path is the identity, so the column is the source's own key.
      def side(schema, clauses, equation, path)
        return qualify(clauses.root_alias, schema.table(equation.from).key) if path.empty?

        far = path[0..-2].reduce(clauses.aliases.first) do |source, fk|
          join(schema, clauses, source, fk, schema.target_of(source[0], fk))
        end
        qualify(far[1], path.last)
      end

      def filter(clauses, table_alias, step)
        field, value, operator = step
        clauses.wheres << "#{qualify(table_alias, field)} #{COMPARISONS.fetch(operator)} ?"
        clauses.binds << value
        clauses
      end

      def null(clauses, step)
        clauses.wheres << "#{qualify(clauses.alias_now, step[0])} IS #{'NOT ' unless step[1]}NULL"
        clauses
      end

      def grouped(query, image)
        keys = query.grouping.map { |field| qualify(GROUP_ALIAS, field) }
        folds = query.aggregates.map { |aggregate| aggregate.sql(GROUP_ALIAS, quote: method(:quote)) }
        "SELECT #{(keys + folds).join(', ')} FROM (#{image}) #{quote(GROUP_ALIAS)} " \
          "GROUP BY #{keys.join(', ')}#{having(query)}#{order_by(query)}#{window(query)}"
      end

      def having(query)
        return '' if query.havings.empty?

        clauses = query.havings.map { |name, _value, operator| "#{quote(name)} #{COMPARISONS[operator]} ?" }
        " HAVING #{clauses.join(' AND ')}"
      end

      def where_clause(wheres)
        wheres.empty? ? '' : " WHERE #{wheres.join(' AND ')}"
      end

      def qualified_fields(query, clauses)
        fields = query.projection || query.schema.table(query.carrier).fields
        fields.map { |field| qualify(clauses.alias_now, field) }
      end

      # The order that is actually applied is the total one, so the two models
      # cannot disagree about how ties fall.
      def order_by(query)
        return '' unless query.ordered?

        ordered = query.total_ordering.map { |o| "#{quote(o.field)} #{o.direction.to_s.upcase}" }
        " ORDER BY #{ordered.join(', ')}"
      end

      def window(query)
        return '' unless query.limit_rows || query.offset_rows

        offset = " OFFSET #{query.offset_rows}" if query.offset_rows
        " LIMIT #{query.limit_rows || UNBOUNDED}#{offset}"
      end

      def qualify(table_alias, field)
        "#{quote(table_alias)}.#{quote(field)}"
      end

      def insert_statement(table, row)
        fields = row.keys
        ["INSERT INTO #{quote(table.name)} (#{fields.map { |field| quote(field) }.join(', ')}) " \
         "VALUES (#{(['?'] * fields.size).join(', ')})",
         fields.map { |field| row[field] }]
      end

      # --- the statements that change rows ------------------------------------
      # Each of these carries the arrow's own guard *inside* the statement that
      # acts on it. That is the difference the surface exists for: the engine
      # decides which rows are in the subobject while it holds them, so no value
      # read into Ruby earlier is what decided.

      # `:add` names the column on both sides — `"stock" = "stock" + ?` — so the
      # new value is a function of the old one, computed by the engine from
      # whatever the old one is by the time the row is held. A negative delta is
      # the decrement; there is no second operation for it. `Change.ordered` is
      # the one reading of a changes Hash, so the assignment list is in the order
      # the Hash was written and three models cannot disagree about that either.
      def update_statement(query, changes)
        sets, values = assignments(changes)
        guarded, guard_binds = guard(query)
        ["UPDATE #{quote(query.carrier)} SET #{sets.join(', ')}#{guarded}", values + guard_binds]
      end

      def assignments(changes)
        Change.ordered(changes).each_with_object([[], []]) do |(field, change), (sets, values)|
          column = quote(field)
          sets << "#{column} = #{change.kind == :add ? "#{column} + ?" : '?'}"
          values << change.operand
        end
      end

      # The deletion a connection that counts its own changes can run: the
      # subobject named by the guard, with no key list to name it by and nothing
      # read first.
      def delete_statement(query)
        guarded, binds = guard(query)
        ["DELETE FROM #{quote(query.carrier)}#{guarded}", binds]
      end

      # How large that subobject is, for a connection that cannot say how many
      # rows its own statement touched. It is the same guard, so the measurement
      # and the statement cannot drift into naming different sets.
      def count_statement(query)
        guarded, binds = guard(query)
        ["SELECT COUNT(*) FROM #{quote(query.carrier)}#{guarded}", binds]
      end

      # The subobject an operation names, said as a condition rather than as a
      # list of keys read out first. Where the walk took no join the columns need
      # no alias: the statement already stands on the one table they belong to,
      # so the condition is the arrow's own `where` clauses verbatim.
      def guard(query)
        return joined_guard(query) if query.steps.any? { |kind, _| %i[follow pullback].include?(kind) }

        conditions, binds = carrier_conditions(query)
        [where_clause(conditions), binds]
      end

      def carrier_conditions(query)
        query.steps.each_with_object([[], []]) do |(kind, field, operand, operator), (conditions, binds)|
          case kind
          when :where
            conditions << "#{quote(field)} #{COMPARISONS.fetch(operator)} ?"
            binds << operand
          when :null
            conditions << "#{quote(field)} IS #{'NOT ' unless operand}NULL"
          end
        end
      end

      # A composition and a pullback both emit a join, and a join inside an
      # `UPDATE` or a `DELETE` is dialect-bound — `UPDATE ... FROM` on postgres,
      # another spelling elsewhere. So the join stays in a subquery and the
      # statement names its rows by the key that subquery selects. Still one
      # statement, and the guard is still the engine's to evaluate rather than a
      # set of keys carried back and forth.
      def joined_guard(query)
        clauses = walk(query)
        key = query.schema.table(query.carrier).key
        [" WHERE #{quote(key)} IN (SELECT #{qualify(clauses.alias_now, key)} " \
         "#{source_clause(query, clauses)})", clauses.binds]
      end

      # A morphism with no value, in one statement per foreign key. The reading
      # this replaces built the diagnostic out of arrows — every row of the
      # source and every key of the target — which is elegant and is proportional
      # to all the data for a question the database answers with an anti-join.
      #
      # `OR ... IS NULL` is load-bearing. `NOT IN` over a NULL is UNKNOWN, so the
      # element whose morphism has no value *at all* — the one most worth
      # reporting — would fall out of both sides of the anti-join and be reported
      # by neither. It is asked for explicitly, which is what keeps this at the
      # reading the model that evaluates in Set has.
      def dangling_statement(schema, table, field, target)
        column = quote(field)
        "SELECT DISTINCT #{column} FROM #{quote(table.name)} " \
          "WHERE #{column} NOT IN (SELECT #{quote(schema.table(target).key)} FROM #{quote(target)}) " \
          "OR #{column} IS NULL"
      end

      # A deletion names its rows by key, and how many it removed is measured
      # with the same subobject — so both statements are built here, together,
      # and cannot drift into naming different sets.
      def delete_statements(table, keys)
        where = "WHERE #{quote(table.key)} IN (#{(['?'] * keys.size).join(', ')})"
        [["DELETE FROM #{quote(table.name)} #{where}", keys],
         ["SELECT COUNT(*) FROM #{quote(table.name)} #{where}", keys]]
      end

      def create_table_statement(table)
        columns = table.fields.map do |field|
          "#{quote(field)} #{sql_type(table.column_type(field))}#{' PRIMARY KEY' if field == table.key}"
        end
        "CREATE TABLE #{quote(table.name)} (#{columns.join(', ')})"
      end

      # `follow` and the pullback both compile to `JOIN target ON source.fk =
      # target.key`, so every foreign key column sits on the probe side of a join
      # by construction. An index on it is part of what declaring the morphism
      # meant, not a knob to reach for after a slow morning — which is why this
      # is derived from the schema rather than from a hint.
      #
      # `[[sql, binds], ...]`, the shape `DDL.ddl` answers with, so a migration
      # can splice it in. `create_table_statement` keeps its single String: a
      # caller that wants the table wants one statement, and the indexes are a
      # second question with a second answer.
      def index_statements(table)
        table.foreign_keys.keys.map do |field|
          ["CREATE INDEX #{quote(index_name(table, field))} ON #{quote(table.name)} (#{quote(field)})", []]
        end
      end

      # Derived from the arrow rather than generated, so the same schema names
      # the same index every time and a later migration can find it again.
      def index_name(table, field)
        "index_#{table.name}_on_#{field}"
      end

      def sql_type(spec)
        case spec.to_s.delete_suffix('?').to_sym
        when :integer then 'INTEGER'
        when :float, :number then 'REAL'
        else 'TEXT'
        end
      end
    end

    # A model backed by anything that answers `execute(sql, binds) -> rows`,
    # where a row is an Array of values in the order asked for. One method is
    # still the whole *mandatory* port, so sqlite3, pg, or a fake all plug in the
    # same way and the gem depends on none of them.
    #
    # A connection **may** answer a second, `change(sql, binds) -> Integer`, with
    # the rows its statement affected. It is a capability the connection
    # declares, not a requirement: every operation below has a reading that uses
    # `execute` alone, the two readings answer with the same count, and a
    # connection that never heard of it works exactly as before. What declaring
    # it buys is the difference between one statement and a round trip
    # proportional to the rows — `execute` reports no affected-row count, so
    # without it a deletion has to name every doomed row by key and then count
    # what is left of them.
    class Sql # rubocop:disable Metrics/ClassLength
      include Ledger

      # A deletion names its rows by key, one placeholder each, and every driver
      # caps how many placeholders one statement may carry — SQLite's default is
      # 999. So the bound is not a tuning knob: without it a deletion fails at
      # exactly the size where deleting it mattered.
      #
      # It belongs to the measured reading alone. A connection that answers
      # `change` deletes by the guard itself, in a statement with no key list in
      # it, and there is nothing left for a chunk to bound.
      DELETE_CHUNK = 500

      attr_reader :schema

      # Whether DDL survives a rollback is a property of the database, and the
      # port cannot ask: `execute(sql, binds) -> rows` has nowhere to put the
      # question. So the caller answers it once, where the connection is built.
      # `true` is the default because SQLite and Postgres both have it; a model
      # over MySQL says `transactional_ddl: false` and is refused a migration
      # rather than left to half-apply one.
      def initialize(schema, connection, transactional_ddl: true)
        @schema = schema.is_a?(History) ? schema.schema : schema
        @connection = connection
        @history = schema if schema.is_a?(History)
        @transactional_ddl = transactional_ddl
      end

      # The whole schema in one shot, with **no ledger behind it** — which is
      # what the name says and why it says it. `verify!` reads the ledger and
      # nothing else, so a database built this way is refused at boot with
      # "database is missing required migrations". Anything that boots against
      # `verify!` goes through `migrate!` instead; this is for a suite that
      # wants a shape and has no history to get it from.
      #
      # The indexes are created with the table because the morphisms are declared
      # with it: a join over an unindexed foreign key is the schema's own shape
      # being paid for again at every read.
      def create_tables_for_test!
        @schema.tables.each_value do |table|
          @connection.execute(SQL.create_table_statement(table), [])
          SQL.index_statements(table).each { |sql, binds| @connection.execute(sql, binds) }
        end
        self
      end

      def select(query)
        sql, binds = SQL.compile(query)
        binds += query.havings.map { |having| having[1] }
        fields = query.output_fields
        rows = @connection.execute(sql, binds).map { |values| fields.zip(values).to_h }
        return Listing[rows, schema: query.row_schema] if query.ordered?

        Relation[rows, schema: query.row_schema]
      end

      def insert(table_name, row)
        table = @schema.table(table_name)
        typed = table.row_schema.load(row.to_h { |field, value| [field.to_s, value] })
        raise SchemaError, "#{table_name}: #{typed.violations.join('; ')}" unless typed.ok?

        sql, binds = SQL.insert_statement(table, table.fields.to_h { |field| [field, row[field]] })
        @connection.execute(sql, binds)
        row[table.key]
      end

      # A change is judged before anything is emitted — `updatable!` refuses an
      # arrow that is not a subobject of the carrier, a guard that is a pullback,
      # and a change no column of it carries — and then applied in one statement
      # with that guard inside it.
      #
      # Which is the whole operation. `SELECT`, `DELETE`, `INSERT` inside one
      # scope is atomic and is not serialisable under READ COMMITTED: two scopes
      # both read `stock = 1` and both write `0`. Here the engine evaluates the
      # guard and computes `stock + ?` while it holds the row, so there is no
      # earlier read for either of them to have taken.
      #
      # The count is the rows the change applied to, and it is how a caller
      # learns it lost: a guarded decrement that comes back `0` found no row
      # left to decrement. A connection that answers `change` has the count from
      # the engine. Otherwise it is measured, and measured *before* the
      # statement rather than after — a change moves rows out of the subobject
      # that named them, which is exactly what `stock = stock - 1` under
      # `stock > 0` does — with both readings in one scope, so nothing else can
      # move a row between them.
      def update(query, changes, confirm_carrier: nil)
        query.updatable!(changes, confirm_carrier: confirm_carrier)
        statement = SQL.update_statement(query, changes)
        return @connection.change(*statement) if counts_changes?

        atomically do
          named = @connection.execute(*SQL.count_statement(query)).dig(0, 0)
          @connection.execute(*statement)
          named
        end
      end

      # A deletion is a subobject of the carrier, which is a thing an arrow can
      # fail to be — so the arrow is judged first, and `confirm_carrier` is how a
      # caller says out loud that it means to remove rows of a codomain.
      #
      # One statement where the connection can say how many rows it removed: the
      # guard goes inside the `DELETE`, and no doomed row is read at all.
      #
      # Where it cannot, the count has to be *measured*, and measuring it is what
      # makes the rows worth naming: the keys go out in one statement per chunk
      # inside one scope, and what was removed is the keys named minus the ones
      # still there once the statement has run. Both readings happen inside that
      # scope, so nothing else can move a row between them. The count this
      # replaces was taken before the delete and reported rows a dropped key had
      # made it miss.
      def delete(query, confirm_carrier: nil)
        query.deletable!(confirm_carrier: confirm_carrier)
        return @connection.change(*SQL.delete_statement(query)) if counts_changes?

        table = @schema.table(query.carrier)
        atomically do
          keys = select(query).rows.map { |row| row[table.key] }
          keys.each_slice(DELETE_CHUNK).sum { |chunk| delete_chunk(table, chunk) }
        end
      end

      # --- the functor laws, checkable ---------------------------------------
      # A dangling foreign key is not a bad row. It is a failure to be a functor:
      # the morphism `posts -> users` has no value at that element.
      #
      # Reported, not enforced. `insert` does not check it and the DDL emits no
      # `REFERENCES`, because referential integrity is a property of the instance
      # that the schema ledger already pins — and a property you can measure is a
      # different object from a constraint the storage engine holds for you. The
      # sentence comes from the schema so all three models say it identically.
      def functor?
        violations.empty?
      end

      def violations
        @schema.tables.each_value.flat_map do |table|
          table.foreign_keys.flat_map { |field, target| dangling(table, field, target) }
        end
      end

      # The anti-join the fragment has no word for, asked of the database in one
      # statement instead of built out of two arrows and a set difference taken
      # in Ruby. The arrows read every row of the source and every key of the
      # target to answer it, which is the whole instance for a question the
      # engine answers where it stands.
      #
      # The sentence still comes from the schema, so one broken morphism cannot
      # come back as three different sentences. The order is taken on the
      # rendering rather than on the values: a key is whatever the schema said it
      # was, and two of them need not be comparable to each other, while the
      # sentences always are.
      def dangling(table, field, target)
        @connection.execute(SQL.dangling_statement(@schema, table, field, target), [])
                   .map { |row| @schema.dangling_message(table.name, field, row.first, target) }
                   .sort
      end

      # --- the path equations, checkable --------------------------------------
      # The condition a foreign key cannot carry: it relates a column to a key,
      # never a path to a path. So `employee.manager.department =
      # employee.department` is declared in the presentation, and measured here.
      #
      # Reported, not enforced — the same standing as referential integrity, and
      # for the same reason. Nothing calls this on `insert` and the DDL emits no
      # `CHECK`; an instance either satisfies the equation or does not, and this
      # is how it is asked.
      #
      # An element with no image on either side is not reported: it falls out of
      # the join, or out of `<>` over a NULL, and it is already reported as a
      # dangling key. `Memory` is brought to the same reading deliberately, so
      # the three agree about which elements have anything to say.
      def satisfies_equations?
        equation_violations.empty?
      end

      def equation_violations
        @schema.equations.flat_map { |equation| unequal(equation) }
      end

      # One statement per equation, and not an arrow: the comparison is between
      # two columns, and `where` compares an attribute to a value. That is
      # exactly what makes this constraint unsayable as an arrow, and worth
      # putting in the presentation instead.
      def unequal(equation)
        @connection.execute(SQL.equation_statement(@schema, equation), []).map do |element, left, right|
          @schema.equation_message(equation, element, left, right)
        end
      end

      # --- migration ----------------------------------------------------------
      LEDGER = 'sodalite_migrations'
      MIGRATION_LOCK = 'sodalite_migration_lock'

      # Everything on the lock row except the `id` that makes it a single row.
      # One list, because the insert and the read have to name the same columns
      # in the same order for the positional rows the port answers with to mean
      # anything.
      LOCK_COLUMNS = %i[token holder acquired_at].freeze

      def read_ledger
        ensure_ledger!
        columns = "#{SQL.quote(:fingerprint)}, #{SQL.quote(:step)}"
        @connection.execute("SELECT #{columns} FROM #{SQL.quote(LEDGER)}", []).to_h
      end

      def record_step(step)
        ensure_ledger!
        @connection.execute("INSERT INTO #{SQL.quote(LEDGER)} " \
                            "(#{SQL.quote(:fingerprint)}, #{SQL.quote(:step)}) VALUES (?, ?)",
                            [step.fingerprint, step.to_s])
        nil
      end

      def forget_step(step)
        ensure_ledger!
        @connection.execute("DELETE FROM #{SQL.quote(LEDGER)} WHERE #{SQL.quote(:fingerprint)} = ?",
                            [step.fingerprint])
        nil
      end

      def carry(step)
        DDL.ddl(step, @schema).each { |sql, binds| @connection.execute(sql, binds) }
        nil
      end

      def transactional_ddl? = @transactional_ddl

      # A migration step's scope. Same depth counter `atomically` uses, so a
      # migration run from inside a scope joins that scope rather than asking
      # the driver for a second `BEGIN` it has no answer for.
      #
      # What differs from `atomically` is what unwinds it. There, rollback is
      # what an `Err` *result* means; a migration block has no result to speak
      # of — `record_step` answers `nil` — so the only thing that can end this
      # scope early is a raise, and a raise ends it.
      def migration_scope
        @depth = (@depth || 0) + 1
        outermost = @depth == 1
        @connection.execute('BEGIN', []) if outermost
        result = yield
        @connection.execute('COMMIT', []) if outermost
        result
      rescue StandardError
        @connection.execute('ROLLBACK', []) if outermost
        raise
      ensure
        @depth -= 1
      end

      # The row is `id = 1` and the table's primary key is what makes it one, so
      # two runners racing here are settled by the database rather than by a
      # `WHERE NOT EXISTS` both of them can pass. The loser's insert fails.
      #
      # The rescue is deliberately broad, and this is the one place that is
      # right: the port is `execute(sql, binds) -> rows`, so the uniqueness
      # error arrives as whatever class the driver chose — sqlite3, pg, and a
      # fake each raise something different, and none of them is nameable from
      # here without depending on a driver the gem does not depend on. So the
      # exception is not the answer. The row is: whoever's token is in it won,
      # and that is a fact the port *can* read.
      def claim_lock(token) # rubocop:disable Naming/PredicateMethod
        ensure_lock!
        insert_lock(token)
        lock_row&.first == token
      end

      def read_lock
        ensure_lock!
        row = lock_row
        row && { token: row[0], holder: row[1], acquired_at: row[2] }
      end

      def release_lock(token)
        ensure_lock!
        @connection.execute("DELETE FROM #{SQL.quote(MIGRATION_LOCK)} " \
                            "WHERE #{SQL.quote(:id)} = 1 AND #{SQL.quote(:token)} = ?", [token])
        nil
      end

      private

      # The optional half of the port, asked of the connection rather than
      # configured: a connection either answers `change(sql, binds)` or it does
      # not, and there is nothing for a caller to get wrong about it.
      def counts_changes?
        @connection.respond_to?(:change)
      end

      def insert_lock(token)
        columns = LOCK_COLUMNS.map { |column| SQL.quote(column) }.join(', ')
        @connection.execute("INSERT INTO #{SQL.quote(MIGRATION_LOCK)} (#{SQL.quote(:id)}, #{columns}) " \
                            'VALUES (1, ?, ?, ?)', [token, lock_holder, lock_acquired_at])
      rescue StandardError
        nil
      end

      def lock_row
        columns = LOCK_COLUMNS.map { |column| SQL.quote(column) }.join(', ')
        @connection.execute("SELECT #{columns} FROM #{SQL.quote(MIGRATION_LOCK)} " \
                            "WHERE #{SQL.quote(:id)} = 1", []).first
      end

      def distinct_values(table, field)
        @connection.execute("SELECT DISTINCT #{SQL.quote(field)} FROM #{SQL.quote(table)}", []).map(&:first)
      end

      def key_holders(sources, key)
        key = SQL.quote(key)
        sources.each_with_object(Hash.new { |all, value| all[value] = [] }) do |source, holders|
          @connection.execute("SELECT #{key} FROM #{SQL.quote(source)}", [])
                     .each { |row| holders[row.first] << source }
        end
      end

      # The keys are named twice — once to remove them, once to count what is
      # left of them — and the second reading is the measurement, so it has to
      # run against the same set the first one did.
      def delete_chunk(table, keys)
        doomed, survivors = SQL.delete_statements(table, keys)
        @connection.execute(*doomed)
        keys.size - @connection.execute(*survivors).dig(0, 0)
      end

      def ensure_ledger!
        @connection.execute("CREATE TABLE IF NOT EXISTS #{SQL.quote(LEDGER)} " \
                            "(#{SQL.quote(:fingerprint)} TEXT PRIMARY KEY, #{SQL.quote(:step)} TEXT)", [])
      end

      # `IF NOT EXISTS` leaves a table an older version of this file created
      # alone, and that one has neither `holder` nor `acquired_at` — so the
      # first claim against it fails on the missing column rather than quietly
      # working. That is the honest failure and the recovery is one statement:
      # the lock table holds nothing between migrations, so drop it and let this
      # build it again. Widening it in place would be a migration of the
      # migration table, and this change does not write one.
      def ensure_lock!
        columns = "#{SQL.quote(:id)} INTEGER PRIMARY KEY, " \
                  "#{LOCK_COLUMNS.map { |column| "#{SQL.quote(column)} TEXT" }.join(', ')}"
        @connection.execute("CREATE TABLE IF NOT EXISTS #{SQL.quote(MIGRATION_LOCK)} (#{columns})", [])
      end

      public

      # Same shape as the memory model's: the caller never asks for a rollback,
      # it is what `Err` means here too, and a nested scope joins the outermost
      # one rather than opening a second — `Memory#atomically` carries the prose
      # for why, and what it costs. Here the counter decides who says `BEGIN`
      # and who gets to end it; an inner scope says neither, because SQL has no
      # second `BEGIN` to give it.
      #
      # `@depth` is not a constructor line because a scope is the only thing
      # that ever moves it, and the `ensure` is what keeps a raise from leaving
      # it behind.
      def atomically
        @depth = (@depth || 0) + 1
        outermost = @depth == 1
        @connection.execute('BEGIN', []) if outermost
        result = yield
        @connection.execute(result.is_a?(Berylx::Err) ? 'ROLLBACK' : 'COMMIT', []) if outermost
        result
      rescue StandardError
        @connection.execute('ROLLBACK', []) if outermost
        raise
      ensure
        @depth -= 1
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
