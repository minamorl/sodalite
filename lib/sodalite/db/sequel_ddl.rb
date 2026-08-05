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
        when :rename_table then rename_table(table, rest[0])
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
      # says the column is the constant default. The backfill is not optional —
      # but rewriting every row to supply a constant is a cost the hand-written
      # emitter stopped paying, and the two models pay the same costs or the
      # conformance between them is only about answers.
      #
      # So the default is declared on the column, where the backend fills the
      # existing rows from the schema, and the update is narrowed to the rows
      # that are still missing a value: a no-op once the declaration has done it,
      # and safe to run again after an interrupted migration. Sequel spells both,
      # because it is the backend here and the dialect is its to know.
      def add_column(table, field, default)
        definition = @schema.table(table)
        type = type_of(definition, field)
        options = default.nil? ? {} : { default: default }
        @db.alter_table(table) { add_column(field, type, **options) }
        @db[table].where(field => nil).update(field => default) unless default.nil?
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

      # An index survives `RENAME TO` under the name it was created with, so a
      # renamed object keeps indexes named after the object it used to be —
      # names nothing can compute again, and names a later object taking the
      # freed name collides with. Sequel does not carry them across either, so
      # they are dropped and re-declared, which is what the hand-written model
      # emits for the same step.
      def rename_table(before, renamed)
        @db.rename_table(before, renamed)
        table = @schema.table(renamed)
        table.foreign_keys.each_key do |field|
          @db.drop_index(renamed, field, name: index_name(before, field))
          @db.add_index(renamed, field, name: index_name(renamed, field))
        end
      end

      def create_table(table)
        key = table.key
        columns = table.fields.map { |field| [field, type_of(table, field)] }
        indexes = table.foreign_keys.keys.map { |field| [field, index_name(table.name, field)] }
        @db.create_table(table.name) do
          columns.each { |field, type| column(field, type, primary_key: field == key) }
          indexes.each { |field, name| index(field, name: name) }
        end
      end

      # Every morphism out of this object compiles to a join on its column —
      # `follow` and a pullback emit the same one — so an index on it follows from
      # the presentation rather than from tuning applied to it afterwards. Sequel
      # spells it inside `create_table` and emits its own `CREATE INDEX` after the
      # table, which is what a backend that cannot put one inline needs.
      #
      # The name is not spelled here. A name the backend invents is a name the
      # other models cannot agree with, and a name spelled twice is a name that
      # can drift — so both readings come from the one rule in `SQL`.
      def index_name(table, field)
        SQL.index_name(DDL::Named.new(name: table), field).to_sym
      end

      # A foreign key column holds the target's key, so its type is the target's
      # key type — `Integer` only when the target's key is one. Reading
      # `attributes` here would find nothing for a morphism and reading the FK as
      # an integer would be a lie the row schema does not tell, so both go through
      # the one accessor that resolves it.
      def type_of(table, field)
        SQL_TYPES.fetch(table.column_type(field).to_s.delete_suffix('?').to_sym, String)
      end
    end
  end
end
