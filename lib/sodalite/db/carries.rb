# frozen_string_literal: true

module Sodalite
  module DB
    # The instance half of a migration for the in-memory model: what the functor
    # on presentations induces on the rows.
    module Carries
      # Mirrors `Step#apply` on the presentation side: the object-level changes
      # here, the field-level ones next door.
      def carry(step)
        table, *rest = step.args
        case step.kind
        when :create_table then @store[table] ||= []
        when :drop_table then @store.delete(table)
        when :rename_table then @store[rest[0]] = @store.delete(table)
        when :merge_tables then merge_rows(table, rest[0], rest[1])
        when :split_table then split_rows(table, rest[0], rest[1])
        else carry_fields(step, table, rest)
        end
      end

      # The coproduct on instances: the disjoint union, with each element
      # carrying the injection it came through.
      def merge_rows(sources, into, tag)
        @store[into] = sources.flat_map do |source|
          @store.fetch(source).map { |row| row.merge(tag => source.to_s) }
        end
        sources.each { |source| @store.delete(source) }
      end

      def split_rows(table, tag, into)
        rows = @store.fetch(table)
        into.each_value { |name| @store[name.to_sym] = [] }
        rows.each do |row|
          name = into.fetch(row[tag])
          @store[name.to_sym] << row.except(tag)
        end
        @store.delete(table)
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
