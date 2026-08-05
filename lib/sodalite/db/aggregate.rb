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
    # None of them combines values of `A + 1`, which is where a nullable column
    # actually lives: `+` is defined on `A`, and min/max adjoin `nothing` as an
    # identity rather than as something `<` can be asked about. So the `+ 1` is
    # eliminated before the fold rather than branched around inside `combine` —
    # see `Aggregate#fold`. Handing a column straight to `combine` is how
    # `total + nothing` and `nothing < best` reach arithmetic with no answer.
    #
    # The identity is what an empty fold means, and both models have to mean it.
    # SQL disagrees about `sum` — `SUM(x)` over no rows is `NULL`, not `0` — so
    # `sum` is emitted coalesced: the monoid is the pinned meaning and SQL is
    # brought to it, not the other way round. `min`/`max` need no such repair,
    # because `NULL` is the identity they already adjoined.
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
                        sql: ->(_column) { 'COUNT(*)' }),
      sum: Monoid.new(identity: 0, combine: ->(total, value) { total + value },
                      sql: ->(column) { "COALESCE(SUM(#{column}), 0)" }),
      min: Monoid.new(identity: nil, combine: ->(best, value) { best.nil? || value < best ? value : best },
                      sql: ->(column) { "MIN(#{column})" }),
      max: Monoid.new(identity: nil, combine: ->(best, value) { best.nil? || value > best ? value : best },
                      sql: ->(column) { "MAX(#{column})" })
    }.freeze

    Aggregate = Data.define(:name, :kind, :field) do
      def monoid
        MONOIDS.fetch(kind)
      end

      # Reading a nullable column is the partial map `A + 1 ⇀ A`, so it is taken
      # as one: the `nothing`s are dropped and the monoid only ever sees `A`. It
      # is the same explicit elimination as `where_present`, moved to where the
      # fold needs it, and it is what SQL's aggregates already do by skipping
      # `NULL`. A fibre that is all `nothing` therefore folds to the identity.
      #
      # `count` has no field and folds the rows of the fibre themselves, which is
      # why the drop cannot reach it: `COUNT(*)` counts elements of the fibre,
      # not of a column, and a row whose columns are all `nothing` is an element.
      def fold(rows)
        return monoid.fold(rows) unless field

        monoid.fold(rows.map { |row| row[field] }.compact)
      end

      # The whole `<fold> AS <name>` fragment, so no caller spells half of it
      # again and the two halves cannot drift apart. What the fragment does not
      # know is the caller's: the qualifier, because the fold reads its column out
      # of whatever the caller aliased the image to, and the quoting, because
      # that belongs to a dialect and is threaded in rather than guessed at here.
      # Threaded in, not re-implemented around: a caller that spells the fragment
      # itself to get its quotes back is the duplication this method removes.
      def sql(qualifier = nil, quote: :to_s.to_proc)
        "#{monoid.sql.call(column(qualifier, quote))} AS #{quote.call(name)}"
      end

      private

      # `count` has no column to qualify, and `COUNT(*)` is not counting one.
      def column(qualifier, quote)
        return nil unless field

        qualifier ? "#{quote.call(qualifier)}.#{quote.call(field)}" : quote.call(field)
      end
    end

    # An ordering is not a relational operation. It does not change the set; it
    # chooses a presentation of it — an iso to `{1..n}` — which is why the result
    # of an ordered query is a `Listing` and not a `Relation`.
    Ordering = Data.define(:field, :direction)
  end
end
