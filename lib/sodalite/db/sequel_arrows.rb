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

      def phase_one(query)
        aliases = [[query.root, :t0]]
        rows = @db[::Sequel[query.root].as(:t0)]
        query.steps.each { |kind, *rest| rows = step(rows, aliases, kind, rest, query) }
        rows.distinct.select(*fields_of(query, aliases.last[1]))
      end

      def step(rows, aliases, kind, rest, query)
        case kind
        when :follow then follow(rows, aliases, rest, query)
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

      def aggregate_of(aggregate)
        function = if aggregate.field
                     ::Sequel.function(aggregate.kind, column(:g, aggregate.field))
                   else
                     ::Sequel.function(:count).*
                   end
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
