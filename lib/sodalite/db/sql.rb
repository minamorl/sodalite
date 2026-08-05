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
      # MySQL only under `ANSI_QUOTES` — the same dialect caveat `Sql#claim_lock`
      # carries about `FROM DUAL`. An embedded quote is doubled, which is how the
      # standard escapes one.
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
        def self.for(query)
          root = [query.root, 't0']
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
        clauses = query.steps.reduce(Clauses.for(query)) do |walk, (kind, *rest)|
          phase_one(query, kind, rest, walk)
        end
        ["SELECT #{'DISTINCT ' if query.distinct?}#{qualified_fields(query, clauses).join(', ')} " \
         "FROM #{quote(query.root)} #{quote(clauses.root_alias)}" \
         "#{clauses.joins.join}#{where_clause(clauses.wheres)}", clauses.binds]
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
        clauses.with(carrier: join(query, clauses, clauses.carrier, fk, target))
      end

      # The pullback `f*(S)`. It emits the join a composition emits and then
      # leaves the carrier where it was, so what comes back is a subobject of the
      # domain: "posts whose author lives in tokyo" answers with posts. A path of
      # length n is n hops, each one a morphism out of the object the last
      # arrived at.
      def pullback(query, clauses, step)
        paths, field, operand, operator = step
        far = paths.reduce(clauses.carrier) do |source, fk|
          join(query, clauses, source, fk, query.schema.target_of(source[0], fk))
        end
        filter(clauses, far[1], [field, operand, operator])
      end

      # `JOIN target ON source.fk = target.key`, and the pair the target is
      # reached by. Composition and the pullback emit the same join; they differ
      # only in whether the carrier follows it.
      def join(query, clauses, source, fk, target)
        key = query.schema.table(target).key
        target_alias = clauses.hop(target)
        clauses.joins << " JOIN #{quote(target)} #{quote(target_alias)} " \
                         "ON #{qualify(source[1], fk)} = #{qualify(target_alias, key)}"
        [target, target_alias]
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
    # where a row is an Array of values in the order asked for. One method is the
    # whole port, so sqlite3, pg, or a fake all plug in the same way and the gem
    # depends on none of them.
    class Sql # rubocop:disable Metrics/ClassLength
      include Ledger

      # A deletion names its rows by key, one placeholder each, and every driver
      # caps how many placeholders one statement may carry — SQLite's default is
      # 999. So the bound is not a tuning knob: without it a deletion fails at
      # exactly the size where deleting it mattered.
      DELETE_CHUNK = 500

      attr_reader :schema

      def initialize(schema, connection)
        @schema = schema.is_a?(History) ? schema.schema : schema
        @connection = connection
        @history = schema if schema.is_a?(History)
      end

      # The indexes are created with the table because the morphisms are declared
      # with it: a join over an unindexed foreign key is the schema's own shape
      # being paid for again at every read.
      def create_tables!
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

      # A deletion is a subobject of the carrier, which is a thing an arrow can
      # fail to be — so the arrow is judged first, and `confirm_carrier` is how a
      # caller says out loud that it means to remove rows of a codomain.
      #
      # The rows go in one statement per chunk inside one scope, so a driver that
      # dies halfway leaves the whole subobject standing rather than an arbitrary
      # part of it removed.
      #
      # The count is what was actually removed, and it is *measured*: the port
      # answers with rows and no affected-row count, so it is the keys named
      # minus the ones still there once the statement has run. Both readings
      # happen inside the same scope, so nothing else can move a row between
      # them. The count this replaces was taken before the delete and reported
      # rows a dropped key had made it miss.
      def delete(query, confirm_carrier: nil)
        query.deletable!(confirm_carrier: confirm_carrier)
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

      # Two arrows and a set difference, rather than the anti-join the fragment
      # has no word for: the elements of the source, and the keys the morphism is
      # supposed to land in.
      def dangling(table, field, target)
        keys = keys_of(target)
        loose = select(@schema[table.name]).reject { |row| keys.include?(row[field]) }
        loose.map { |row| @schema.dangling_message(table.name, field, row[field], target) }
      end

      def keys_of(target)
        key = @schema.table(target).key
        select(@schema[target].select(key)).to_set { |row| row[key] }
      end

      # --- migration ----------------------------------------------------------
      LEDGER = 'sodalite_migrations'
      MIGRATION_LOCK = 'sodalite_migration_lock'

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

      def claim_lock(token) # rubocop:disable Naming/PredicateMethod
        ensure_lock!
        lock = SQL.quote(MIGRATION_LOCK)
        id = SQL.quote(:id)
        # This spelling targets SQLite/Postgres; MySQL requires `FROM DUAL`, and
        # reads the quotes above as strings unless `ANSI_QUOTES` is set.
        @connection.execute("INSERT INTO #{lock} (#{id}, #{SQL.quote(:token)}) SELECT 1, ? " \
                            "WHERE NOT EXISTS (SELECT 1 FROM #{lock})", [token])
        @connection.execute("SELECT #{SQL.quote(:token)} FROM #{lock} WHERE #{id} = 1", []).dig(0, 0) == token
      end

      def release_lock(token)
        ensure_lock!
        @connection.execute("DELETE FROM #{SQL.quote(MIGRATION_LOCK)} " \
                            "WHERE #{SQL.quote(:id)} = 1 AND #{SQL.quote(:token)} = ?", [token])
        nil
      end

      private

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

      def ensure_lock!
        @connection.execute("CREATE TABLE IF NOT EXISTS #{SQL.quote(MIGRATION_LOCK)} " \
                            "(#{SQL.quote(:id)} INTEGER PRIMARY KEY, #{SQL.quote(:token)} TEXT)", [])
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
