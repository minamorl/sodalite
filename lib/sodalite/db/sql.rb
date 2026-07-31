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

        ["SELECT DISTINCT #{columns(query, aliases)} FROM #{query.root} t0#{joins.join}" \
         "#{" WHERE #{wheres.join(' AND ')}" unless wheres.empty?}", binds]
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

      def columns(query, aliases)
        current = aliases.last[1]
        fields = query.projection || query.schema.table(query.carrier).fields
        fields.map { |field| "#{current}.#{field}" }.join(', ')
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
        fields = query.projection || @schema.table(query.carrier).fields
        rows = @connection.execute(sql, binds).map { |values| fields.zip(values).to_h }
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
