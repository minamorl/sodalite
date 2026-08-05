# frozen_string_literal: true

module Sodalite
  module DB
    # What a value becomes, said as a value.
    #
    # With the signature at select / insert / delete / atomically, changing a
    # value meant reading the row, deleting it, and inserting the changed version
    # inside `atomically`. That is atomic, and it is not serialisable: a plain
    # `BEGIN` on postgres is READ COMMITTED, so two scopes both read `stock = 1`,
    # the second's `DELETE` blocks on the first, and when it wakes it re-evaluates
    # its `WHERE` against a row that is already gone, removes nothing, and then
    # inserts a row computed from the read it took before any of that happened.
    # One decrement is lost and the item is oversold.
    #
    # A fifth operation that assigned literals would carry exactly the same
    # hazard, and this is the thing worth being clear about, because it makes the
    # shape below look arbitrary until it is said. The hazard is not in the number
    # of statements. It is in where the new value came from: `SET stock = 0`
    # computed that `0` from a read taken earlier, and the row it lands on need
    # not be the row that was read. What removes it is writing the new value as a
    # **function of the old one** — `stock = stock - 1` — with the guard evaluated
    # inside the same statement, so the engine applies the function under its own
    # row lock and to whatever the value is by then. The arrow never sees the
    # value, so there is nothing for it to have seen too early.
    #
    # Which is why this is a closed vocabulary and not an expression language.
    # `:set` and `:add` are the two things a change may be, on the same rule that
    # kept `avg` out of the aggregates: what is offered is what carries a law.
    Change = Data.define(:kind, :operand) do
      # A bare value in a changes Hash means `:set`, so `{ state: 'sold' }` and
      # `{ state: DB.set('sold') }` are one change. The rule is written here and
      # nowhere else — three models each spelling it would be three places for it
      # to be spelled differently, and the difference would only show on the Hash
      # that used the bare form.
      #
      # Idempotent, so a caller that has already normalised does not have to
      # remember whether it did.
      def self.of(value) = value.is_a?(Change) ? value : new(kind: :set, operand: value)

      # The one reading of a changes Hash: its pairs, normalised, in the order
      # they were written. Declaration order **is** the order, and it is fixed.
      # Assignment is order-independent to a database, but the models are compared
      # by what they emit, so three readings of one Hash would be three statements
      # for one change and the disagreement would be about nothing.
      def self.ordered(changes) = changes.map { |field, change| [field.to_sym, of(change)] }.freeze
    end

    # Addition, with a signed operand. There is no `subtract`: a decrement is
    # `add` of a negative delta, which leaves one operation to judge, one to
    # compile, and one for three models to agree about. Two spellings of one arrow
    # would be three more chances for them to disagree, bought for a word.
    def self.add(delta) = Change[:add, delta]

    # Assignment. Here for symmetry, and because `Change.of` reads a `Change` as
    # already normalised — so a column whose value *is* a `Change` can only be set
    # by saying so.
    def self.set(value) = Change[:set, value]

    # The types that carry addition. A change of kind `:add` is a subobject of
    # nothing on the others: strings have concatenation, which is not the same
    # monoid, and times have a difference but no sum.
    ADDITIVE_TYPES = %i[integer float number].freeze

    # What an update can be wrong about beyond what a deletion can. These live
    # beside the vocabulary they judge rather than with the other query checks:
    # they are laws about a change and about where its guard is evaluated, and
    # `QueryChecks` was already split once for its length.
    module ChangeChecks
      private

      # The load-bearing refusal, and the reason the whole surface exists.
      #
      # A pullback's guard is a join, and a join inside an `UPDATE` is
      # dialect-bound — `UPDATE ... FROM` on postgres, another spelling
      # elsewhere, nothing portable. Allowing it would mean evaluating the guard
      # in a `SELECT` taken before the statement, which is exactly the stale read
      # this operation was built to remove.
      def check_no_pullback!
        return unless steps.any? { |kind, _| kind == :pullback }

        raise QueryError,
              "update of #{carrier} cannot be guarded by a pullback — the guard has to be evaluated " \
              'inside the update statement, and a join there is dialect-bound (UPDATE ... FROM on ' \
              'postgres, another spelling elsewhere, nothing portable), so allowing it would push the ' \
              'guard back into a select taken earlier, which is the lost update this exists to remove'
      end

      # Judged once, here, so that three models lowering the same Hash cannot
      # differ about which of them it was a change of.
      def check_changes!(changes)
        check_change_present!(changes)
        Change.ordered(changes).each do |field, change|
          check_field!(field)
          check_not_key!(field)
          check_addable!(field, change)
        end
      end

      def check_change_present!(changes)
        return unless changes.empty?

        raise QueryError,
              "an update of #{carrier} needs a change — the empty one is the identity, and a " \
              'statement that changes nothing is not an operation on rows'
      end

      # The key is what a row *is*, not something it holds. Reassigning it makes
      # the row the models each answer about a different row from the one they
      # named, so the count they come back with is a count of different things.
      def check_not_key!(field)
        key = schema.table(carrier).key
        return unless field == key

        raise QueryError,
              "#{carrier}.#{key} is the identity of a row, not a value to reassign — change it and " \
              'the models no longer agree about which row they changed'
      end

      # Judged on the type, the way an order comparison is, rather than on taste.
      # The nullable spelling is the same type over `A + 1`, so it is read through
      # `base_type` instead of being listed twice.
      def check_addable!(field, change)
        return unless change.kind == :add
        return if ADDITIVE_TYPES.include?(base_type(field))

        raise QueryError,
              "#{carrier}.#{field} is #{schema.table(carrier).column_type(field).inspect}, which " \
              'carries no addition, so add is not a change of it'
      end
    end
  end
end
