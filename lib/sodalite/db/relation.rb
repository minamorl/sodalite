# frozen_string_literal: true

module Sodalite
  module DB
    # The result of an arrow: a set, because the regular fragment's projection is
    # an image. A set has no first element, so `Relation` offers none — asking
    # for one means asking for an order, and an order gives you a `Listing`.
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

    # An ordered presentation of a relation. The set did not change; a total
    # order was chosen for it, which is what makes `first` and a window mean
    # something. Equality is by sequence here, not by set — that is the whole
    # difference between the two types.
    Listing = Data.define(:rows, :schema) do
      include Enumerable

      def self.[](rows, schema: nil)
        new(rows: rows.freeze, schema: schema)
      end

      def each(&) = rows.each(&)
      def size = rows.size
      def empty? = rows.empty?
      def first(count = nil) = count ? rows.first(count) : rows.first

      def typed
        raise QueryError, 'a projected listing has no row type' unless schema

        rows.map { |row| schema.load!(row.transform_keys(&:to_s)) }
      end

      def to_relation
        Relation[rows, schema: schema]
      end
    end
  end
end
