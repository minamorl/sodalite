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
        aliases = [[query.root, 't0']]
        joins = []
        wheres = []
        binds = []

        query.steps.each do |kind, *rest|
          case kind
          when :follow then follow(query, aliases, joins, rest)
          when :where  then where(aliases, wheres, binds, rest)
          end
        end

        source = "FROM #{query.root} t0#{joins.join}#{where_clause(wheres)}"
        [query.grouped? ? grouped(query, aliases, source) : flat(query, aliases, source), binds]
      end

      def flat(query, aliases, source)
        "SELECT DISTINCT #{qualified_fields(query, aliases).join(', ')} #{source}" \
          "#{order_by(query)}#{window(query)}"
      end

      # `follow` is composition **followed by image factorization**, so it yields
      # a set. A SQL `JOIN` yields the pullback, which keeps one row per pair —
      # so folding straight over the join counts multiplicities of the join
      # rather than elements of the image, and `posts.follow(:author)` would
      # report a city twice for an author with two posts.
      #
      # The image therefore has to be taken *before* the fold, which is what this
      # derived table is. For an ungrouped root the DISTINCT is a no-op, so the
      # same shape is correct either way.
      #
      # The two-model conformance suite is what caught this; nothing about the
      # SQL looked wrong.
      def grouped(query, aliases, source)
        image = "SELECT DISTINCT #{qualified_fields(query, aliases).join(', ')} #{source}"
        keys = query.grouping.map { |field| "g.#{field}" }
        folds = query.aggregates.map do |aggregate|
          "#{aggregate.monoid.sql.call("g.#{aggregate.field}")} AS #{aggregate.name}"
        end
        "SELECT #{(keys + folds).join(', ')} FROM (#{image}) g GROUP BY #{keys.join(', ')}" \
          "#{order_by(query)}#{window(query)}"
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
        field, value = step
        wheres << "#{aliases.last[1]}.#{field} = ?"
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
      attr_reader :schema

      def initialize(schema, connection)
        @schema = schema
        @connection = connection
      end

      def create_tables!
        @schema.tables.each_value { |table| @connection.execute(SQL.create_table_statement(table), []) }
        self
      end

      def select(query)
        sql, binds = SQL.compile(query)
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

      # Same shape as the memory model's: the caller never asks for a rollback,
      # it is what `Err` means here too.
      def atomically
        @connection.execute('BEGIN', [])
        result = yield
        @connection.execute(result.is_a?(Berylx::Err) ? 'ROLLBACK' : 'COMMIT', [])
        result
      rescue StandardError
        @connection.execute('ROLLBACK', [])
        raise
      end
    end
  end
end
