# frozen_string_literal: true

module Sodalite
  module DB
    # The instance half of a migration for the in-memory model: what the functor
    # on presentations induces on the rows. `applied` is this model's ledger; the
    # SQL model keeps the same thing in a table.
    module Carries
      # The induced map on instances. `applied` is this model's ledger; the SQL
      # model keeps the same thing in a table.
      attr_reader :applied

      def migrate!(history)
        history.steps.each_with_index do |step, version|
          next if @applied.include?(version)

          @schema = history.schema_at(version + 1)
          carry(step)
          @applied << version
        end
        self
      end

      # Mirrors `Step#apply` on the presentation side: the object-level changes
      # here, the field-level ones next door.
      def carry(step)
        table, *rest = step.args
        case step.kind
        when :create_table then @store[table] ||= []
        when :drop_table then @store.delete(table)
        when :rename_table then @store[rest[0]] = @store.delete(table)
        else carry_fields(step, table, rest)
        end
      end

      def carry_fields(step, table, rest)
        case step.kind
        when :add_attribute then each_row(table) { |row| row[rest[0]] = step.default }
        when :drop_attribute then each_row(table) { |row| row.delete(rest[0]) }
        when :rename_attribute then each_row(table) { |row| row[rest[1]] = row.delete(rest[0]) }
        end
      end

      def each_row(table, &)
        @store.fetch(table).each(&)
      end
    end
  end
end
