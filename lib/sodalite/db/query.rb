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
    # Equality is the regular fragment. An order comparison is still an honest
    # subobject *when the attribute type carries an order*, which is why the
    # check is on the type rather than on taste. Negation is the one that
    # genuinely breaks: `NOT (x = 3)` over a nullable column is three-valued, so
    # it is refused there and allowed where the type is a plain set.
    COMPARISONS = { eq: '=', not: '<>', gt: '>', gte: '>=', lt: '<', lte: '<=' }.freeze
    ORDERED_TYPES = %i[integer float number time string].freeze
    NO_OPERAND = ::Object.new.freeze

    Query = Data.define(:schema, :root, :carrier, :steps, :unions, :grouping, :aggregates,
                        :havings, :orderings, :limit_rows, :offset_rows) do
      include QueryChecks
      include QueryPhases

      def self.start(schema, root)
        new(schema: schema, root: root, carrier: root, steps: [].freeze, unions: [].freeze,
            grouping: nil, aggregates: [].freeze, havings: [].freeze, orderings: [].freeze,
            limit_rows: nil, offset_rows: nil)
      end

      def united?
        !unions.empty?
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
        check_not_united!(:follow)
        target = schema.target_of(carrier, fk)
        with(carrier: target, steps: (steps + [[:follow, fk.to_sym, target]]).freeze)
      end

      # A subobject of the current carrier.
      #
      #   where(:city, 'tokyo')        equality — the regular fragment
      #   where(:age, :gte, 18)        an order comparison, if the type is ordered
      #   where(:city, :not, 'tokyo')  a complement, if the type is not nullable
      #
      # Comparing to `nil` is refused in every form. A nullable column is a map
      # into `A + 1`, and eliminating the `+ 1` is `where_null` / `where_present`
      # — explicitly, because SQL's silent answer to `x = NULL` is `UNKNOWN`.
      def where(field, operator_or_value, value = NO_OPERAND)
        check_fragment_open!(:where)
        check_not_united!(:where)
        operator, operand = comparison(operator_or_value, value)
        check_field!(field)
        check_comparison!(field, operator, operand)
        with(steps: (steps + [[:where, field.to_sym, operand, operator]]).freeze)
      end

      # The pullback. For a morphism `f : posts -> users` and a subobject `S` of
      # users, `f*(S)` is a subobject of *posts* — the elements whose image under
      # f lands in S. `follow` hands you S instead, which is why "posts whose
      # author lives in tokyo" cannot be written with it: the composite yields
      # users, and the posts were the thing being asked about.
      #
      #   posts.where_at(:author, :city, 'tokyo')
      #   comments.where_along(%i[post author], :city, 'tokyo')
      #
      # So the carrier does not move. The field and the comparison are checked
      # against the object at the end of the path rather than against the carrier,
      # and SQL emits the same JOIN it emits for a composition — it just leaves
      # the carrier's alias as the one later steps qualify against. Which side of
      # the span the result is read from is the whole difference.
      #
      # This is not a fourth primitive: it is `where`, formed along a path, and
      # phase one is still composition, subobject, image.
      def where_at(path, field, operator_or_value, value = NO_OPERAND)
        where_along([path], field, operator_or_value, value)
      end

      def where_along(paths, field, operator_or_value, value = NO_OPERAND)
        check_fragment_open!(:where_along)
        check_not_united!(:where_along)
        paths = Array(paths).map(&:to_sym)
        target = path_target(paths)
        operator, operand = comparison(operator_or_value, value)
        check_field!(field, target)
        check_comparison!(field, operator, operand, target)
        with(steps: (steps + [[:pullback, paths.freeze, field.to_sym, operand, operator]]).freeze)
      end

      # The explicit elimination of `A + 1`: the fibre over `nothing`, and its
      # complement. Only on a nullable attribute, because on a plain set they
      # would be a tautology and a contradiction dressed up as a filter.
      def where_null(field)
        check_nullable!(field, :where_null)
        with(steps: (steps + [[:null, field.to_sym, true]]).freeze)
      end

      def where_present(field)
        check_nullable!(field, :where_present)
        with(steps: (steps + [[:null, field.to_sym, false]]).freeze)
      end

      # The coproduct. SQL spells it `UNION`, which deduplicates — so it is the
      # coproduct followed by image factorization, which is exactly set union and
      # exactly what a `Relation` means.
      #
      # Both sides must be subobjects of the same carrier with the same output,
      # or their coproduct is not a relation over anything. A union closes phase
      # one: the result is a set built from C's objects rather than one of them,
      # so C's morphisms no longer apply to it.
      def union(other)
        check_unionable!(other)
        with(unions: (unions + [other]).freeze)
      end

      # Image factorization: project, and therefore deduplicate. A projection
      # that kept duplicates would not be the image.
      def select(*fields)
        check_fragment_open!(:select)
        check_not_united!(:select)
        fields = fields.flatten.map(&:to_sym)
        fields.each { |field| check_field!(field) }
        with(steps: (steps + [[:select, fields.freeze]]).freeze)
      end

      def output_fields
        return grouping + aggregates.map(&:name) if grouped?

        projection || schema.table(carrier).fields
      end

      def projection
        step = steps.reverse.find { |kind, _| kind == :select }
        step && step[1]
      end

      # Whether the image still has to be taken. `SELECT DISTINCT` is how SQL
      # spells image factorization, and there is exactly one thing in phase one
      # that gives it work to do.
      #
      # `follow` moves the carrier to the codomain, whose fibres can hold more
      # than one element, so the join repeats a target row once per element over
      # it and the duplicates are real. A pullback join cannot do that: it is
      # taken along a function, every element has exactly one image, and the row
      # source keeps one row per element of the carrier. With no `follow` at all,
      # keeping the carrier's key in the output makes the tuples distinct by that
      # key's own uniqueness, and the dedupe is sorting for nothing.
      #
      # One answer, on the query, because three models each deciding this for
      # themselves is three chances to decide it differently.
      def distinct?
        return true if steps.any? { |kind, _| kind == :follow }

        !output_fields.include?(schema.table(carrier).key)
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
    end
  end
end
