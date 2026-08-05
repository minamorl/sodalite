# frozen_string_literal: true

module Sodalite
  module DB
    # Lowering an arrow onto Sequel's expression API. The same three phases as
    # everywhere else — the arrow, the fold, the presentation — spelled in
    # datasets instead of in SQL text, so a dialect that wants `OFFSET` written
    # differently gets it written differently without the meaning moving.
    module SequelArrows
      private

      def dataset(query)
        rows = coproduct(query)
        rows = fold(query, rows) if query.grouped?
        query.ordered? ? present(query, rows) : rows
      end

      def coproduct(query)
        query.unions.reduce(phase_one(query)) { |rows, other| rows.union(phase_one(other)) }
      end

      # `DISTINCT` is how SQL spells image factorization, and it is applied when
      # there is an image left to take. `Query#distinct?` is the one place that
      # decides, because three models each deciding it for themselves is three
      # chances to decide it differently.
      def phase_one(query)
        aliases = [[query.root, :t0]]
        rows = @db[::Sequel[query.root].as(:t0)]
        query.steps.each { |kind, *rest| rows = step(rows, aliases, kind, rest, query) }
        rows = rows.distinct if query.distinct?
        rows.select(*fields_of(query, aliases.last[1]))
      end

      def step(rows, aliases, kind, rest, query)
        case kind
        when :follow then follow(rows, aliases, rest, query)
        when :pullback then pullback(rows, aliases, rest, query)
        when :where then rows.where(condition(aliases.last[1], rest))
        when :null then if rest[1]
                          rows.where(column(aliases.last[1],
                                            rest[0]) => nil)
                        else
                          rows.exclude(column(aliases.last[1],
                                              rest[0]) => nil)
                        end
        else rows
        end
      end

      # Composition. Sequel spells it `JOIN`, for the same reason SQL does.
      def follow(rows, aliases, rest, query)
        fk, target = rest
        source = aliases.last[1]
        next_alias = :"t#{aliases.size}"
        key = query.schema.table(target).key
        aliases << [target, next_alias]
        rows.join(::Sequel[target].as(next_alias), key => column(source, fk))
      end

      # The pullback: `f*(S)` is a subobject of the *carrier*, so this emits the
      # join a composition emits and differs only in which side of the span the
      # rows are read from. The path's aliases are pushed exactly as `follow`
      # pushes them — a path of length > 1 is a chain of joins — and then the
      # carrier's is pushed back on top, because `aliases.last` is what every later
      # step and the projection qualify against, and a pullback does not move it.
      #
      # The comparison goes through the same `condition` a `where` goes through, so
      # the operators cannot mean one thing along a path and another at the
      # carrier.
      def pullback(rows, aliases, rest, query)
        paths, *comparison = rest
        carrier = aliases.last
        joined = paths.reduce(rows) do |dataset, fk|
          follow(dataset, aliases, [fk, query.schema.target_of(aliases.last[0], fk)], query)
        end
        target = aliases.last[1]
        aliases << carrier
        joined.where(condition(target, comparison))
      end

      def condition(table_alias, step)
        field, value, operator = step
        left = column(table_alias, field)
        case operator
        when :eq then { left => value }
        when :not then ::Sequel.~(left => value)
        when :gt then left > value
        when :gte then left >= value
        when :lt then left < value
        when :lte then left <= value
        end
      end

      # The image before the fold, exactly as in the hand-written model:
      # `from_self` is how Sequel wraps a relation so the group counts elements of
      # the image rather than multiplicities of a join.
      def fold(query, rows)
        keys = query.grouping.map { |field| column(:g, field) }
        grouped = rows.from_self(alias: :g)
                      .group(*keys)
                      .select(*keys, *query.aggregates.map { |aggregate| aggregate_of(aggregate) })
        query.havings.reduce(grouped) { |dataset, having| dataset.having(condition(nil, having)) }
      end

      # The same fold `Aggregate` spells as text, spelled as an expression. It has
      # to mean the same thing, and for `sum` that costs a `COALESCE`: SQL answers
      # `NULL` for a fibre whose column is entirely nothing, while the monoid's
      # identity is `0`. The monoid is the pinned meaning and the backend is
      # brought to it — so the identity comes from the monoid rather than being
      # typed out again here. `min`/`max` need no repair, because `NULL` is the
      # identity they already adjoined, and `COUNT(*)` never answers it.
      def aggregate_of(aggregate)
        function = if aggregate.field
                     ::Sequel.function(aggregate.kind, column(:g, aggregate.field))
                   else
                     ::Sequel.function(:count).*
                   end
        function = ::Sequel.function(:coalesce, function, aggregate.monoid.identity) if aggregate.kind == :sum
        function.as(aggregate.name)
      end

      def present(query, rows)
        ordered = rows.order(*query.total_ordering.map do |ordering|
          ordering.direction == :desc ? ::Sequel.desc(ordering.field) : ::Sequel.asc(ordering.field)
        end)
        ordered.limit(query.limit_rows, query.offset_rows)
      end

      def fields_of(query, table_alias)
        (query.projection || @schema.table(query.carrier).fields).map { |field| column(table_alias, field) }
      end

      def column(table_alias, field)
        table_alias ? ::Sequel[table_alias][field] : ::Sequel[field]
      end
    end
  end
end
