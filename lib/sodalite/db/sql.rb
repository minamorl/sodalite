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
    module SQL
      module_function

      def compile(query)
        rows, binds = coproduct(query)
        [query.grouped? ? grouped(query, rows) : "#{rows}#{order_by(query)}#{window(query)}", binds]
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

      # The three accumulators a phase-one walk fills travel together, so they
      # are one value rather than three parameters passed in step.
      Clauses = Data.define(:aliases, :joins, :wheres, :binds) do
        def self.for(query) = new(aliases: [[query.root, 't0']], joins: [], wheres: [], binds: [])
        def alias_now = aliases.last[1]
      end

      def row_source(query)
        clauses = Clauses.for(query)
        query.steps.each { |kind, *rest| phase_one(query, kind, rest, clauses) }
        ["SELECT DISTINCT #{qualified_fields(query, clauses.aliases).join(', ')} " \
         "FROM #{query.root} t0#{clauses.joins.join}#{where_clause(clauses.wheres)}", clauses.binds]
      end

      def phase_one(query, kind, rest, clauses)
        case kind
        when :follow then follow(query, clauses.aliases, clauses.joins, rest)
        when :where  then where(clauses.aliases, clauses.wheres, clauses.binds, rest)
        when :null   then clauses.wheres << "#{clauses.alias_now}.#{rest[0]} IS #{'NOT ' unless rest[1]}NULL"
        end
      end

      def grouped(query, image)
        keys = query.grouping.map { |field| "g.#{field}" }
        folds = query.aggregates.map do |aggregate|
          "#{aggregate.monoid.sql.call("g.#{aggregate.field}")} AS #{aggregate.name}"
        end
        "SELECT #{(keys + folds).join(', ')} FROM (#{image}) g GROUP BY #{keys.join(', ')}" \
          "#{having(query)}#{order_by(query)}#{window(query)}"
      end

      def having(query)
        return '' if query.havings.empty?

        clauses = query.havings.map { |name, _value, operator| "#{name} #{COMPARISONS[operator]} ?" }
        " HAVING #{clauses.join(' AND ')}"
      end

      def where_clause(wheres)
        wheres.empty? ? '' : " WHERE #{wheres.join(' AND ')}"
      end

      def qualified_fields(query, aliases)
        fields = query.projection || query.schema.table(query.carrier).fields
        fields.map { |field| qualify(aliases, field) }
      end

      # The order that is actually applied is the total one, so the two models
      # cannot disagree about how ties fall.
      def order_by(query)
        return '' unless query.ordered?

        " ORDER BY #{query.total_ordering.map { |o| "#{o.field} #{o.direction.to_s.upcase}" }.join(', ')}"
      end

      def window(query)
        return '' unless query.limit_rows || query.offset_rows

        "#{query.limit_rows ? " LIMIT #{query.limit_rows}" : ' LIMIT -1'}" \
          "#{" OFFSET #{query.offset_rows}" if query.offset_rows}"
      end

      def qualify(aliases, field)
        "#{aliases.last[1]}.#{field}"
      end

      def follow(query, aliases, joins, step)
        fk, target = step
        source_table, source = aliases.last
        next_alias = "t#{aliases.size}"
        key = query.schema.table(target).key
        joins << " JOIN #{target} #{next_alias} ON #{source}.#{fk} = #{next_alias}.#{key}"
        aliases << [target, next_alias]
        source_table
      end

      def where(aliases, wheres, binds, step)
        field, value, operator = step
        wheres << "#{aliases.last[1]}.#{field} #{COMPARISONS.fetch(operator)} ?"
        binds << value
      end

      def insert_statement(table, row)
        fields = row.keys
        ["INSERT INTO #{table.name} (#{fields.join(', ')}) VALUES (#{(['?'] * fields.size).join(', ')})",
         fields.map { |field| row[field] }]
      end

      def create_table_statement(table)
        columns = table.fields.map do |field|
          type = table.foreign_keys.key?(field) ? 'INTEGER' : sql_type(table.attributes[field])
          "#{field} #{type}#{' PRIMARY KEY' if field == table.key}"
        end
        "CREATE TABLE #{table.name} (#{columns.join(', ')})"
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
    class Sql
      include Ledger

      attr_reader :schema

      def initialize(schema, connection)
        @schema = schema.is_a?(History) ? schema.schema : schema
        @connection = connection
        @history = schema if schema.is_a?(History)
      end

      def create_tables!
        @schema.tables.each_value { |table| @connection.execute(SQL.create_table_statement(table), []) }
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

      def delete(query)
        doomed = select(query)
        table = @schema.table(query.carrier)
        doomed.rows.each do |row|
          @connection.execute("DELETE FROM #{table.name} WHERE #{table.key} = ?", [row[table.key]])
        end
        doomed.size
      end

      # --- migration ----------------------------------------------------------
      LEDGER = 'sodalite_migrations'
      MIGRATION_LOCK = 'sodalite_migration_lock'

      def read_ledger
        ensure_ledger!
        @connection.execute("SELECT fingerprint, step FROM #{LEDGER}", []).to_h
      end

      def record_step(step)
        ensure_ledger!
        @connection.execute("INSERT INTO #{LEDGER} (fingerprint, step) VALUES (?, ?)",
                            [step.fingerprint, step.to_s])
        nil
      end

      def forget_step(step)
        ensure_ledger!
        @connection.execute("DELETE FROM #{LEDGER} WHERE fingerprint = ?", [step.fingerprint])
        nil
      end

      def carry(step)
        DDL.ddl(step, @schema).each { |sql, binds| @connection.execute(sql, binds) }
        nil
      end

      def claim_lock(token) # rubocop:disable Naming/PredicateMethod
        ensure_lock!
        # This spelling targets SQLite/Postgres; MySQL requires `FROM DUAL`.
        @connection.execute(
          "INSERT INTO #{MIGRATION_LOCK} (id, token) SELECT 1, ? " \
          "WHERE NOT EXISTS (SELECT 1 FROM #{MIGRATION_LOCK})", [token]
        )
        @connection.execute("SELECT token FROM #{MIGRATION_LOCK} WHERE id = 1", []).dig(0, 0) == token
      end

      def release_lock(token)
        ensure_lock!
        @connection.execute("DELETE FROM #{MIGRATION_LOCK} WHERE id = 1 AND token = ?", [token])
        nil
      end

      private

      def ensure_ledger!
        @connection.execute("CREATE TABLE IF NOT EXISTS #{LEDGER} " \
                            '(fingerprint TEXT PRIMARY KEY, step TEXT)', [])
      end

      def ensure_lock!
        @connection.execute("CREATE TABLE IF NOT EXISTS #{MIGRATION_LOCK} " \
                            '(id INTEGER PRIMARY KEY, token TEXT)', [])
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
    end
  end
end
