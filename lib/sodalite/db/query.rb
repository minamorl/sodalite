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
    # Leaving the fragment — ordering, limits, aggregation, negation — is not a
    # missing feature to add later. Those live outside a regular category, and
    # the escape hatch for them is declared raw SQL with a zeolite schema typing
    # the result, so the way out is as typed as the way in.
    Query = Data.define(:schema, :root, :carrier, :steps) do
      def self.start(schema, root)
        new(schema: schema, root: root, carrier: root, steps: [].freeze)
      end

      # Composition. The carrier moves to the codomain of the morphism, so what
      # you may filter on afterwards changes with it — checked here, at build
      # time, not on the request that first runs the query.
      def follow(fk)
        target = schema.target_of(carrier, fk)
        with(carrier: target, steps: (steps + [[:follow, fk.to_sym, target]]).freeze)
      end

      # A subobject of the current carrier. Equality only: `=` and `∧` and `∃`
      # are the regular fragment, and `NOT` is where SQL stops being a category
      # and becomes three-valued logic.
      def where(field, value)
        check_field!(field)
        raise QueryError, "where on #{carrier}.#{field} cannot compare to nil" if value.nil?

        with(steps: (steps + [[:where, field.to_sym, value]]).freeze)
      end

      # Image factorization: project, and therefore deduplicate. A projection
      # that kept duplicates would not be the image.
      def select(*fields)
        fields = fields.flatten.map(&:to_sym)
        fields.each { |field| check_field!(field) }
        with(steps: (steps + [[:select, fields.freeze]]).freeze)
      end

      def projection
        step = steps.reverse.find { |kind, _| kind == :select }
        step && step[1]
      end

      # A query with no projection yields whole rows of its carrier, so its
      # result can be typed by the same zeolite schema that types a row.
      def row_schema
        projection ? nil : schema.table(carrier).row_schema
      end

      def to_s
        "#{root}#{steps.map { |kind, *rest| ".#{kind}(#{rest.first})" }.join}"
      end

      private

      def check_field!(field)
        return if schema.table(carrier).field?(field)

        raise QueryError, "#{carrier} has no field #{field.inspect}"
      end
    end

    # The result of an arrow: a set, because the regular fragment's projection is
    # an image. Ordering is not part of the algebra — it is a decoration on a
    # result — so a Relation deliberately offers no `first` and no `sort`.
    Relation = Data.define(:rows, :schema) do
      include Enumerable

      def self.[](rows, schema: nil)
        new(rows: rows.uniq.freeze, schema: schema)
      end

      def each(&) = rows.each(&)
      def size = rows.size
      def empty? = rows.empty?

      # Whole rows can be handed to the same sieve that types a response body.
      def typed
        raise QueryError, 'a projected relation has no row type' unless schema

        rows.map { |row| schema.load!(row.transform_keys(&:to_s)) }
      end

      # Two models agree when their results are equal as sets.
      def ==(other)
        other.is_a?(Relation) && rows.to_set == other.rows.to_set
      end
      alias_method :eql?, :==

      def hash = rows.to_set.hash
    end
  end
end
