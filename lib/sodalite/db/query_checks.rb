# frozen_string_literal: true

module Sodalite
  module DB
    # Everything an arrow can be wrong about, checked when it is built. A query
    # that fails on the one request that happens to exercise it is a query that
    # fails at 3am, so none of these wait until evaluation.
    module QueryChecks
      private

      def check_field!(field)
        return if schema.table(carrier).field?(field)

        raise QueryError, "#{carrier} has no field #{field.inspect}"
      end

      def check_comparison!(field, operator, operand)
        raise QueryError, "unknown comparison #{operator.inspect}" unless COMPARISONS.key?(operator)
        raise QueryError, "#{carrier}.#{field} cannot be compared to nil — use where_null" if operand.nil?

        check_ordered!(field, operator) if %i[gt gte lt lte].include?(operator)
        check_complementable!(field) if operator == :not
      end

      # An order comparison is a subobject only where the type carries an order.
      def check_ordered!(field, operator)
        return if ORDERED_TYPES.include?(base_type(field))

        raise QueryError, "#{carrier}.#{field} has no order, so #{operator} is not a subobject of it"
      end

      # Over `A + 1` the complement of a subobject is not its SQL negation:
      # `NOT (x = 3)` leaves the rows where x is nothing out of both sides.
      def check_complementable!(field)
        return unless nullable?(field)

        raise QueryError,
              "#{carrier}.#{field} is nullable, so its complement is three-valued — " \
              'eliminate the null first with where_present'
      end

      def check_nullable!(field, operation)
        check_fragment_open!(operation)
        check_field!(field)
        return if nullable?(field)

        raise QueryError, "#{carrier}.#{field} is not nullable, so #{operation} is not a filter"
      end

      # A nullable attribute maps into `A + 1`. Folding or ordering its values
      # would let each model silently choose how to eliminate the adjoined
      # point, so the query must first restrict the carrier to `A` explicitly.
      def check_present!(field, operation)
        return unless nullable?(field)
        return if present_fields.include?(field.to_sym)

        raise QueryError,
              "#{carrier}.#{field} is nullable, so #{operation} needs explicit elimination — " \
              'use where_present first'
      end

      def check_order_present!(field)
        return if grouped? && aggregates.any? { |aggregate| aggregate.name == field.to_sym }

        check_present!(field, :order)
      end

      def check_unionable!(other)
        raise QueryError, 'a union needs two arrows over the same carrier' unless other.carrier == carrier
        raise QueryError, 'a union of grouped or ordered arrows is not a relation' if
          grouped? || ordered? || other.grouped? || other.ordered?
        return if other.output_fields == output_fields

        raise QueryError,
              "a union needs the same output: #{output_fields.inspect} vs #{other.output_fields.inspect}"
      end

      def check_not_united!(operation)
        return unless united?

        raise QueryError, "#{operation} cannot follow union — the coproduct is not an object of the schema"
      end

      def nullable?(field)
        declared = schema.table(carrier).attributes[field.to_sym]
        declared.is_a?(Symbol) && declared.to_s.end_with?('?')
      end

      def base_type(field)
        declared = schema.table(carrier).attributes[field.to_sym]
        declared.is_a?(Symbol) ? declared.to_s.delete_suffix('?').to_sym : nil
      end

      # Ordering happens on what the query outputs, not on what it started from.
      def check_output_field!(field)
        return if output_fields.include?(field.to_sym)

        raise QueryError, "#{field.inspect} is not in the result: #{output_fields.inspect}"
      end

      # The fold consumes the relation, so the fragment is closed once it starts.
      # A subobject of a *grouped* relation is `HAVING`, which is a different
      # operation and is not offered yet rather than being quietly conflated.
      def check_fragment_open!(operation)
        return unless grouped?

        raise QueryError, "#{operation} cannot follow group — the fragment ends where the fold begins"
      end
    end
  end
end
