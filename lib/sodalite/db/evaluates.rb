# frozen_string_literal: true

module Sodalite
  module DB
    # Evaluating one arrow in Set: the step interpreter for the in-memory model,
    # kept apart from the store it reads because they answer different questions.
    module Evaluates
      ORDER_TESTS = {
        eq: ->(value, operand) { value == operand },
        not: ->(value, operand) { value != operand },
        gt: ->(value, operand) { value > operand },
        gte: ->(value, operand) { value >= operand },
        lt: ->(value, operand) { value < operand },
        lte: ->(value, operand) { value <= operand }
      }.freeze

      private

      def apply(step, rows)
        kind, *rest = step
        case kind
        when :follow then follow(rows, rest[0], rest[1])
        when :select then rows.map { |row| row.slice(*rest[0]) }.uniq
        else filter(kind, rest, rows)
        end
      end

      def filter(kind, rest, rows)
        return rows.select { |row| row[rest[0]].nil? == rest[1] } if kind == :null

        rows.select { |row| compare?(row[rest[0]], rest[2], rest[1]) }
      end

      # A row whose value is nothing is in neither a subobject nor its
      # complement, which is the whole of what three-valued logic is trying to
      # say. Here it is one line rather than a footgun.
      def compare?(value, operator, operand)
        return false if value.nil?

        ORDER_TESTS.fetch(operator).call(value, operand)
      end

      # Composition, then image: the set of targets actually hit.
      def follow(rows, fk, target)
        wanted = rows.to_set { |row| row[fk] }
        key = @schema.table(target).key
        @store[target].select { |row| wanted.include?(row[key]) }.map(&:dup)
      end
    end
  end
end
