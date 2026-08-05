# frozen_string_literal: true

module Sodalite
  module DB
    # Which places in the instance an arrow's answer depends on.
    #
    # `Address` says what a place is; this says which of them one arrow reads.
    # It is half of the invalidation calculus — an operation says which addresses
    # it dirties, and if the two sets do not meet then that write cannot have
    # changed this answer. Both halves are functions of values already in hand,
    # so nothing here reads the database and nothing here is remembered.
    #
    # It walks the same steps `SQL.walk` walks, for a different purpose, and the
    # two agree about the one thing that is easy to get backwards: which object
    # each step is spoken against. `follow` is composition and moves the carrier
    # to the codomain; a pullback emits the same join and leaves the carrier
    # where it was. Get that wrong and a later `where` is attributed to an object
    # it was never about — an unsoundness no test of the emitted SQL would catch,
    # because the SQL would still be right.
    #
    # Every object the walk touches contributes its `elements`, because an answer
    # depends on which elements each of them has: the root, the codomain of every
    # composition, and every object a pullback path hops through.
    #
    # What a join reads of the object it lands on is `elements` and the morphism
    # that reached it — not the target's key, which the `ON` clause names. That
    # is sound rather than merely short: `check_not_key!` refuses an update of a
    # key, so the only thing that can move a key is an insert or a delete, and
    # those dirty `elements` of that object, which is already here.
    module QueryReads
      # Every place this arrow's answer depends on.
      #
      # Two things deliberately contribute nothing. A `having` names a fold's own
      # output, which is computed here rather than stored, so there is no place
      # in the instance for it to name. A window chooses how much of an order to
      # hand back, and consults no map of any object to do it.
      def reads
        found = walked.merge(row_reads).merge(fold_reads).merge(order_reads)
        unions.reduce(found) { |all, other| all.merge(other.reads) }.freeze
      end

      private

      # Phase one. The reduce carries the object the next step is spoken against,
      # and only a composition moves it — so the object it ends on is the query's
      # own `carrier`, and the later phases read that field instead of this.
      def walked
        found = Set[Address.elements(root)]
        steps.reduce(root) do |object, (kind, *rest)|
          found.merge(step_reads(object, kind, rest))
          kind == :follow ? rest[1] : object
        end
        found
      end

      # Which places one step consults. A kind this has never heard of is a
      # refusal rather than an empty set: reading nothing is exactly the shape of
      # an unsound answer, and the step vocabulary is closed.
      def step_reads(object, kind, rest)
        case kind
        when :follow then [Address.field(object, rest[0]), Address.elements(rest[1])]
        when :pullback then pullback_reads(object, rest)
        when :select then rest[0].map { |field| Address.field(object, field) }
        when :where, :null then [Address.field(object, rest[0])]
        else raise QueryError, "no reading of step #{kind.inspect}"
        end
      end

      # The pullback reads along its whole path and compares at the far end. Each
      # hop consults the morphism it is named by, on the object standing there,
      # and lands on an object whose elements the answer then depends on. The
      # compared field belongs to the object the path arrived at rather than to
      # the carrier — the same distinction `check_field!` makes when the arrow is
      # built, and the carrier is still where it was when this began.
      def pullback_reads(object, step)
        paths, field = step
        found = []
        far = paths.reduce(object) do |source, fk|
          found << Address.field(source, fk)
          target = schema.target_of(source, fk)
          found << Address.elements(target)
          target
        end
        found << Address.field(far, field)
      end

      # An arrow with no projection answers with whole rows of its final carrier,
      # so every map out of that object is consulted — including the ones nobody
      # named. This is the rule most easily missed and the one that keeps the
      # calculus sound: without it an update to a column the arrow never
      # mentioned looks harmless while it changes the answer.
      def row_reads
        return [] if projection

        schema.table(carrier).fields.map { |field| Address.field(carrier, field) }
      end

      # Phase two, on the final carrier: the map whose fibres are the groups, and
      # the column each fold runs over. `count` has no column — it folds the
      # elements of the fibre themselves — so it consults none.
      #
      # A fold cannot follow a projection, so on every arrow that can be built
      # these are already in the whole row above. They are the fold's own
      # addresses even so, and naming them here is what keeps this right if that
      # law ever moves.
      def fold_reads
        (grouping.to_a + aggregates.filter_map(&:field)).map { |field| Address.field(carrier, field) }
      end

      # Phase three, on the final carrier. An ordering names something in the
      # output, which is either a field of the carrier or a fold's own output —
      # and a fold's output is computed rather than stored, so it names no place,
      # exactly as a `having` names none.
      #
      # The completion that makes the order total costs nothing: ungrouped, the
      # tiebreaker is the carrier's key, which `check_orderable!` already
      # required to be in the output; grouped, it is the grouping keys. Either
      # way it adds no address this has not already added.
      def order_reads
        folded = aggregates.map(&:name)
        orderings.map(&:field).reject { |field| folded.include?(field) }
                 .map { |field| Address.field(carrier, field) }
      end
    end
  end
end
