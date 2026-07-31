# frozen_string_literal: true

module Sodalite
  module DB
    class QueryError < StandardError; end

    # An arrow in the schema category, built as data and interpreted by a model.
    #
    # The four operations are the regular fragment, and nothing else is offered:
    #
    #   follow  composition in C            — move along a foreign key
    #   where   a subobject                 — equality only
    #   select  image factorization         — project, and therefore dedupe
    #   (root)  an object of C
    #
    # There is no `join`. A join is not something you write; it is what a
    # compiler emits when you compose two morphisms. `posts.follow(:author)` is
    # the composition, and the SQL model turns it into `JOIN` because that is how
    # SQL spells it. Writing joins by hand is writing the implementation of
    # composition by hand.
    #
    # Grouping and ordering are *not* in that fragment, and they are also not
    # optional for a real service. They are not crammed in either: they are a
    # second phase, held in their own fields rather than in `steps`, because the
    # phases have different laws.
    #
    #   arrow in C   composition / subobject / image   -> Relation, a set
    #   fold         a fold along the fibers of a map  -> Relation of groups
    #   presentation an order, and then a window on it -> Listing, a sequence
    #
    # Each phase is optional, their order is fixed, and both models still have to
    # agree on all three — the conformance suite covers the whole pipeline, not
    # just the fragment.
    Query = Data.define(:schema, :root, :carrier, :steps, :grouping, :aggregates, :orderings,
                        :limit_rows, :offset_rows) do
      def self.start(schema, root)
        new(schema: schema, root: root, carrier: root, steps: [].freeze,
            grouping: nil, aggregates: [].freeze, orderings: [].freeze,
            limit_rows: nil, offset_rows: nil)
      end

      def grouped?
        !grouping.nil?
      end

      def ordered?
        !orderings.empty?
      end

      # Composition. The carrier moves to the codomain of the morphism, so what
      # you may filter on afterwards changes with it — checked here, at build
      # time, not on the request that first runs the query.
      def follow(fk)
        check_fragment_open!(:follow)
        target = schema.target_of(carrier, fk)
        with(carrier: target, steps: (steps + [[:follow, fk.to_sym, target]]).freeze)
      end

      # A subobject of the current carrier. Equality only: `=` and `∧` and `∃`
      # are the regular fragment, and `NOT` is where SQL stops being a category
      # and becomes three-valued logic.
      def where(field, value)
        check_fragment_open!(:where)
        check_field!(field)
        raise QueryError, "where on #{carrier}.#{field} cannot compare to nil" if value.nil?

        with(steps: (steps + [[:where, field.to_sym, value]]).freeze)
      end

      # Image factorization: project, and therefore deduplicate. A projection
      # that kept duplicates would not be the image.
      def select(*fields)
        check_fragment_open!(:select)
        fields = fields.flatten.map(&:to_sym)
        fields.each { |field| check_field!(field) }
        with(steps: (steps + [[:select, fields.freeze]]).freeze)
      end

      # --- phase two: a fold along the fibers of a map ------------------------

      # `group(:city)` is the map `carrier -> city`. Its fibers are the groups,
      # and each aggregate is a monoid folded over one fiber.
      def group(*fields)
        fields = fields.flatten.map(&:to_sym)
        raise QueryError, 'group takes at least one field' if fields.empty?

        fields.each { |field| check_field!(field) }
        with(grouping: fields.freeze)
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

      def output_fields
        return grouping + aggregates.map(&:name) if grouped?

        projection || schema.table(carrier).fields
      end

      def projection
        step = steps.reverse.find { |kind, _| kind == :select }
        step && step[1]
      end

      # A query with no projection yields whole rows of its carrier, so its
      # result can be typed by the same zeolite schema that types a row.
      def row_schema
        return nil if projection || grouped?

        schema.table(carrier).row_schema
      end

      def to_s
        "#{root}#{steps.map { |kind, *rest| ".#{kind}(#{rest.first})" }.join}"
      end

      private

      def check_field!(field)
        return if schema.table(carrier).field?(field)

        raise QueryError, "#{carrier} has no field #{field.inspect}"
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
