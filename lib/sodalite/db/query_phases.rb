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
      #
      # It has to run on the relation and not on an image of it, which is why a
      # projection closes this door from the other side.
      def group(*fields)
        fields = fields.flatten.map(&:to_sym)
        raise QueryError, 'group takes at least one field' if fields.empty?

        check_not_projected!(:group)
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

        check_fold_name!(name)
        check_field!(field) if field
        with(aggregates: (aggregates + [Aggregate.new(name: name.to_sym, kind: kind, field: field)]).freeze)
      end

      # --- phase three: a presentation of the result --------------------------

      # An order that is not total is not a function of the set — two rows that
      # tie may come back either way round, and a paginated client then sees rows
      # repeat or vanish between pages. So the identifying fields are appended,
      # and the order this returns is always total.
      #
      # Which means an image that has already dropped those fields can carry no
      # order at all, and is refused rather than completed: adding the key back
      # would order a wider object than the one that was asked for.
      def order(field, direction = :asc)
        raise QueryError, "unknown direction #{direction.inspect}" unless %i[asc desc].include?(direction)

        check_output_field!(field)
        check_orderable!
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

      # --- what these two phases can be wrong about ---------------------------
      # Their laws live with them for the same reason the phases do: they are
      # laws about a fold and about a presentation, not about an arrow.

      private

      # The other side of the wall `check_fragment_open!` holds from the fold's
      # side. Image factorization has already collapsed the fibres a fold would
      # partition, so a group after a projection folds over one element each and
      # every count answers 1 — in all three models at once, which makes it a
      # trap rather than a disagreement they could be caught by.
      def check_not_projected!(operation)
        return unless projection

        raise QueryError,
              "#{operation} cannot follow select — the image has already collapsed the fibres, " \
              'so each fold would run over a single element'
      end

      # The output of a fold is its grouping keys and its folded values side by
      # side. Two of them under one name is not a wider row: the memory model
      # merges the second over the first and the SQL model emits the column
      # twice, so the name that was asked for is not the one that comes back.
      def check_fold_name!(name)
        name = name.to_sym
        raise QueryError, "#{name.inspect} is a grouping key, and the fold would take its place" if
          grouping.include?(name)
        return unless aggregates.any? { |fold| fold.name == name }

        raise QueryError, "#{name.inspect} is already a fold of this group"
      end

      # The tiebreaker has to be in the output, or the completion that makes an
      # order total has nothing to complete it with. Putting the key back into the
      # projection is not the repair: the image is its own object, and widening it
      # answers a different question than the one that was asked.
      def check_orderable!
        return if grouped?

        key = schema.table(carrier).key
        return if output_fields.include?(key)

        raise QueryError,
              "an order over #{output_fields.inspect} cannot be made total — " \
              "the projection has dropped #{carrier}.#{key}, which is what breaks the ties"
      end
    end
  end
end
