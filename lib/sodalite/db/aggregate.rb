# frozen_string_literal: true

module Sodalite
  module DB
    # `GROUP BY key` takes the map `key : A -> K` and partitions A into its
    # **fibers**. An aggregate is then a fold over each fiber into a monoid —
    # which is not decoration, it is the reason the usable aggregates are exactly
    # the ones below:
    #
    #   count  (N, +, 0)                   every element contributes 1
    #   sum    (N, +, 0)
    #   min    (A + 1, min, nothing)       the identity of min is not in A, so it
    #   max    (A + 1, max, nothing)       is adjoined — the same `A + 1` that
    #                                      makes a nullable column honest
    #
    # `avg` is deliberately absent. It is not a monoid: averages do not combine
    # associatively, which is why every implementation computes it as a pair of
    # monoids (sum, count) and divides at the end. Write that pair if you want it,
    # and the division stays where it belongs — outside the fold.
    Monoid = Data.define(:identity, :combine, :sql) do
      def fold(values)
        values.reduce(identity) { |accumulator, value| combine.call(accumulator, value) }
      end
    end

    MONOIDS = {
      count: Monoid.new(identity: 0, combine: ->(total, _value) { total + 1 },
                        sql: ->(_field) { 'COUNT(*)' }),
      sum: Monoid.new(identity: 0, combine: ->(total, value) { total + value },
                      sql: ->(field) { "SUM(#{field})" }),
      min: Monoid.new(identity: nil, combine: ->(best, value) { best.nil? || value < best ? value : best },
                      sql: ->(field) { "MIN(#{field})" }),
      max: Monoid.new(identity: nil, combine: ->(best, value) { best.nil? || value > best ? value : best },
                      sql: ->(field) { "MAX(#{field})" })
    }.freeze

    Aggregate = Data.define(:name, :kind, :field) do
      def monoid
        MONOIDS.fetch(kind)
      end

      def fold(rows)
        monoid.fold(field ? rows.map { |row| row[field] } : rows)
      end

      def sql
        "#{monoid.sql.call(field)} AS #{name}"
      end
    end

    # An ordering is not a relational operation. It does not change the set; it
    # chooses a presentation of it — an iso to `{1..n}` — which is why the result
    # of an ordered query is a `Listing` and not a `Relation`.
    Ordering = Data.define(:field, :direction)
  end
end
