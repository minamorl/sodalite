# frozen_string_literal: true

module Sodalite
  module DB
    # The statements a migration step turns into. Separate from `SQL` because
    # compiling an arrow and carrying a functor across a database are two jobs,
    # and only one of them is a query.
    module DDL
      module_function

      # DDL is derived from the step, not typed out beside it. A step can need
      # more than one statement, so this always answers with a list of
      # `[sql, binds]` — which is what `add_attribute` needs, because `ADD
      # COLUMN` leaves existing rows NULL while the induced map on instances says
      # the column is the constant default. Backfilling is not a nicety; without
      # it the two models disagree, and the conformance suite says so.
      def ddl(step, schema)
        table, *rest = step.args
        case step.kind
        when :create_table then [[SQL.create_table_statement(schema.table(table)), []]]
        when :drop_table then [["DROP TABLE #{table}", []]]
        when :rename_table then [["ALTER TABLE #{table} RENAME TO #{rest[0]}", []]]
        when :merge_tables then merge_tables(schema, table, rest[0], rest[1])
        when :split_table then split_table(schema, table, rest[0], rest[1])
        else alter(step, schema, table, rest)
        end
      end

      def alter(step, schema, table, rest)
        case step.kind
        when :add_attribute then add_column(schema, table, rest[0], step.default)
        when :drop_attribute then [["ALTER TABLE #{table} DROP COLUMN #{rest[0]}", []]]
        when :rename_attribute then [["ALTER TABLE #{table} RENAME COLUMN #{rest[0]} TO #{rest[1]}", []]]
        end
      end

      # Σ on instances is `INSERT ... SELECT` per injection, then drop the sides.
      def merge_tables(schema, sources, into, tag)
        target = schema.table(into)
        columns = target.fields
        statements = [[SQL.create_table_statement(target), []]]
        sources.each do |source|
          picked = columns.map { |field| field == tag ? '?' : field.to_s }
          statements << ["INSERT INTO #{into} (#{columns.join(', ')}) " \
                         "SELECT #{picked.join(', ')} FROM #{source}", [source.to_s]]
          statements << ["DROP TABLE #{source}", []]
        end
        statements
      end

      def split_table(schema, table, tag, into)
        statements = []
        into.each do |value, name|
          target = schema.table(name)
          statements << [SQL.create_table_statement(target), []]
          columns = target.fields.join(', ')
          statements << ["INSERT INTO #{name} (#{columns}) SELECT #{columns} FROM #{table} WHERE #{tag} = ?",
                         [value]]
        end
        statements << ["DROP TABLE #{table}", []]
        statements
      end

      def add_column(schema, table, field, default)
        definition = schema.table(table)
        type = definition.foreign_keys.key?(field) ? 'INTEGER' : SQL.sql_type(definition.attributes[field])
        statements = [["ALTER TABLE #{table} ADD COLUMN #{field} #{type}", []]]
        statements << ["UPDATE #{table} SET #{field} = ?", [default]] unless default.nil?
        statements
      end
    end
  end
end
