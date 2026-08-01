# frozen_string_literal: true

module Sodalite
  module DB
    # Carrying a migration functor across a Sequel database. Separate from the
    # arrow lowering next door for the same reason `DDL` is separate from `SQL`:
    # compiling a query and reshaping a schema are two jobs, and only one of them
    # is a query.
    module SequelDDL
      SQL_TYPES = { integer: Integer, string: String, float: Float, number: Float,
                    boolean: TrueClass, time: Time }.freeze

      private

      def carry(step)
        table, *rest = step.args
        case step.kind
        when :create_table then create_table(@schema.table(table))
        when :drop_table then @db.drop_table(table)
        when :rename_table then @db.rename_table(table, rest[0])
        when :merge_tables then merge_tables(table, rest[0], rest[1])
        when :split_table then split_table(table, rest[0], rest[1])
        else alter(step, table, rest)
        end
      end

      def alter(step, table, rest)
        case step.kind
        when :add_attribute then add_column(table, rest[0], step.default)
        when :drop_attribute then @db.alter_table(table) { drop_column(rest[0]) }
        when :rename_attribute then @db.alter_table(table) { rename_column(rest[0], rest[1]) }
        end
      end

      # `ADD COLUMN` leaves existing rows NULL, while the induced map on instances
      # says the column is the constant default. The backfill is not optional.
      def add_column(table, field, default)
        definition = @schema.table(table)
        type = type_of(definition, field)
        @db.alter_table(table) { add_column(field, type) }
        @db[table].update(field => default) unless default.nil?
      end

      def merge_tables(sources, into, tag)
        create_table(@schema.table(into))
        columns = @schema.table(into).fields
        sources.each do |source|
          @db[source].each { |row| @db[into].insert(row.merge(tag => source.to_s).slice(*columns)) }
          @db.drop_table(source)
        end
      end

      def split_table(table, tag, into)
        into.each do |value, name|
          create_table(@schema.table(name))
          fields = @schema.table(name).fields
          @db[table].where(tag => value).each { |row| @db[name].insert(row.slice(*fields)) }
        end
        @db.drop_table(table)
      end

      def create_table(table)
        key = table.key
        columns = table.fields.map { |field| [field, type_of(table, field)] }
        @db.create_table(table.name) do
          columns.each { |field, type| column(field, type, primary_key: field == key) }
        end
      end

      def type_of(table, field)
        return Integer if table.foreign_keys.key?(field)

        SQL_TYPES.fetch(table.attributes[field].to_s.delete_suffix('?').to_sym, String)
      end
    end
  end
end
