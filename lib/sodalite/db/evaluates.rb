# frozen_string_literal: true

module Sodalite
  module DB
    # Evaluating one arrow in Set: the step interpreter for the in-memory model,
    # kept apart from the store it reads because they answer different questions.
    module Evaluates
      ORDER_TESTS = {
        eq: ->(value, operand) { value == operand },
        not: ->(value, operand) { value != operand },
        gt: ->(value, operand) { value > operand },
        gte: ->(value, operand) { value >= operand },
        lt: ->(value, operand) { value < operand },
        lte: ->(value, operand) { value <= operand }
      }.freeze

      private

      def apply(step, rows, carrier)
        kind, *rest = step
        case kind
        when :follow then follow(rows, rest[0], rest[1])
        when :select then rows.map { |row| row.slice(*rest[0]) }.uniq
        when :pullback then pullback(rows, carrier, rest)
        else filter(kind, rest, rows)
        end
      end

      # Composition is the only step that moves the carrier, and it already names
      # its own codomain, so the walk reads the carrier off the steps rather than
      # re-deriving it from the schema.
      def carrier_after(step, carrier)
        step[0] == :follow ? step[2] : carrier
      end

      def filter(kind, rest, rows)
        return rows.select { |row| row[rest[0]].nil? == rest[1] } if kind == :null

        rows.select { |row| compare?(row[rest[0]], rest[2], rest[1]) }
      end

      # A row whose value is nothing is in neither a subobject nor its
      # complement, which is the whole of what three-valued logic is trying to
      # say. Here it is one line rather than a footgun.
      def compare?(value, operator, operand)
        return false if value.nil?

        ORDER_TESTS.fetch(operator).call(value, operand)
      end

      # Composition, then image: the set of targets actually hit.
      def follow(rows, fk, target)
        wanted = rows.to_set { |row| row[fk] }
        key = @schema.table(target).key
        @store[target].select { |row| wanted.include?(row[key]) }.map(&:dup)
      end

      # The pullback of a subobject along a path. For `f : posts -> users` and a
      # subobject S of users, `f*(S)` is a subobject of *posts*: the elements
      # whose image under f lands in S. So the carrier does not move, which is
      # the whole difference from `follow` — that lands in the codomain, where
      # the elements being asked about are no longer the ones in hand.
      #
      # Evaluated from the far end back. The subobject at the end of the path is
      # named by its keys, and each hop turns "the keys of this object that are
      # in" into "the keys of the object before it that map into them". A hop
      # therefore costs one scan of one table rather than a lookup per carrier
      # row per hop, and the carrier is walked exactly once, at the end.
      #
      # A row whose foreign key is dangling has no image at all, so it satisfies
      # nothing — not even a predicate every element of the codomain satisfies —
      # and it is dropped. That is the same fact `Memory#violations` reports, and
      # it is why the SQL model's inner join agrees: a row with no target does
      # not join.
      def pullback(rows, carrier, rest)
        paths, field, operand, operator = rest
        visited = path_objects(carrier, paths)
        far = keys_where(visited.last) { |row| compare?(row[field], operator, operand) }
        allowed = walk_back(visited, paths, far)
        rows.select { |row| allowed.include?(row[paths.first]) }
      end

      # The walk back, one hop at a time, stopping at the morphism out of the
      # carrier — that last hop is not taken here, because the carrier's rows are
      # the ones in hand and they are tested rather than named by their keys.
      def walk_back(visited, paths, far)
        visited[0..-2].zip(paths.drop(1)).reverse.reduce(far) do |keys, (table, fk)|
          keys_where(table) { |row| keys.include?(row[fk]) }
        end
      end

      # The objects the path visits, in order — each one the codomain of the
      # morphism named at that hop, starting from where the walk stands.
      def path_objects(carrier, paths)
        paths.each_with_object([]) do |fk, visited|
          visited << @schema.target_of(visited.last || carrier, fk)
        end
      end

      # A subobject of one object, named by its key — which is what the morphism
      # coming into it points at, and so the only thing the next hop back can be
      # pulled along.
      def keys_where(table, &test)
        key = @schema.table(table).key
        @store[table].select(&test).to_set { |row| row[key] }
      end
    end
  end
end
