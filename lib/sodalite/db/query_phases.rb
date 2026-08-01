# frozen_string_literal: true

module Sodalite
  module DB
    # Phases two and three: the fold along the fibers of a map, and the
    # presentation of the result. Kept apart from phase one because they are
    # apart — different laws, different result types, and a fixed order between
    # them.
    module QueryPhases
      # --- phase two: a fold along the fibers of a map ------------------------

      # `group(:city)` is the map `carrier -> city`. Its fibers are the groups,
      # and each aggregate is a monoid folded over one fiber.
      def group(*fields)
        fields = fields.flatten.map(&:to_sym)
        raise QueryError, 'group takes at least one field' if fields.empty?

        fields.each { |field| check_field!(field) }
        with(grouping: fields.freeze)
      end

      # A subobject of the *grouped* relation — which is a different set from the
      # one `where` filters, which is why it is a different word.
      def having(name, operator, value)
        raise QueryError, 'having needs a group to filter' unless grouped?
        raise QueryError, "unknown comparison #{operator.inspect}" unless COMPARISONS.key?(operator)

        check_output_field!(name)
        with(havings: (havings + [[name.to_sym, value, operator]]).freeze)
      end

      def count(as)  = aggregate(as, :count, nil)
      def sum(field, as:) = aggregate(as, :sum, field)
      def min(field, as:) = aggregate(as, :min, field)
      def max(field, as:) = aggregate(as, :max, field)

      def aggregate(name, kind, field)
        raise QueryError, "#{kind} needs a group to fold over" unless grouped?

        check_field!(field) if field
        with(aggregates: (aggregates + [Aggregate.new(name: name.to_sym, kind: kind, field: field)]).freeze)
      end

      # --- phase three: a presentation of the result --------------------------

      # An order that is not total is not a function of the set — two rows that
      # tie may come back either way round, and a paginated client then sees rows
      # repeat or vanish between pages. So the identifying fields are appended,
      # and the order this returns is always total.
      def order(field, direction = :asc)
        raise QueryError, "unknown direction #{direction.inspect}" unless %i[asc desc].include?(direction)

        check_output_field!(field)
        with(orderings: (orderings + [Ordering.new(field: field.to_sym, direction: direction)]).freeze)
      end

      # A window without an order is not a function of the set either; it is
      # whatever the storage engine felt like. So it is a build error, not a
      # footgun to discover in production.
      def limit(rows)
        raise QueryError, 'limit needs an order — a window on an unordered set is not a value' unless ordered?

        with(limit_rows: Integer(rows))
      end

      def offset(rows)
        raise QueryError, 'offset needs an order' unless ordered?

        with(offset_rows: Integer(rows))
      end

      # The order actually applied: what was asked for, made total.
      def total_ordering
        return [] unless ordered?

        tiebreak = (grouped? ? grouping : [schema.table(carrier).key])
        asked = orderings.map(&:field)
        orderings + tiebreak.reject { |field| asked.include?(field) }
                            .map { |field| Ordering.new(field: field, direction: :asc) }
      end
    end
  end
end
