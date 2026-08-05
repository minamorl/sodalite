# frozen_string_literal: true

module Sodalite
  module DB
    # Raised when what an operation dirties cannot be read off the value it was
    # going to be performed with.
    class WritesError < StandardError; end

    # Which places in the instance an operation would dirty.
    #
    # The operation half of the calculus `Address` is the vocabulary of. A query
    # says which addresses it reads, an operation says which it dirties, and the
    # property the two exist for is one line:
    #
    #   writes(operation) disjoint from reads(query)
    #     => performing that operation cannot change that query's answer
    #
    # It takes the tag and the payload — exactly the pair the caller was about to
    # hand `io.perform` — so it performs nothing, reads no database, and holds
    # nothing. The other way to get this answer would be to have the operations
    # *return* what they dirtied, and that widens the effect signature, which is
    # fixed at five and is what three models agree about. Computing it from the
    # payload instead means the framework gains a function and no state, and the
    # question can be asked before the operation runs rather than after.
    #
    # The split between the two kinds of address is what makes the answers worth
    # having, and each operation lands on one side of it:
    #
    #   SELECT  nothing. The empty set is an answer, not a refusal.
    #   INSERT  the elements of the table, and nothing else. An insert changes
    #           which elements exist; it does not change where a map sends an
    #           element that was already there. Every arrow over an object reads
    #           that object's elements, so naming them is sufficient — and it is
    #           tighter than also naming the fields the row filled in, which is
    #           why it is worth being exact about.
    #   DELETE  the elements of the *carrier*, not of the root: a delete through
    #           a composition removes elements of the codomain, which is the
    #           thing `deletable!` makes the caller say out loud.
    #   UPDATE  the fields the changes name, on the carrier, and **not** its
    #           elements — an update cannot make an element appear or disappear.
    #           So an update of `posts.title` leaves a query that only reads
    #           `posts.id` alone. That is the case the whole design exists for,
    #           and the one a scheme addressed at the object gets wrong.
    def self.writes(tag, payload)
      case tag
      when SELECT then Set[]
      when INSERT then Set[Address.elements(payload[0])]
      when UPDATE then changed_fields(payload[0], payload[1])
      when DELETE then Set[Address.elements(payload.carrier)]
      when ATOMICALLY then refuse_scope!
      else refuse_tag!(tag)
      end
    end

    # The fields a change names, addressed on the object whose rows the update
    # names. Read through `Change.ordered` because that is *the* reading of a
    # changes Hash: a bare value and a `Change` are one change, and `'title'` and
    # `:title` are one field. Reading it a second way here would let the set of
    # places disagree with the statement the models are about to emit.
    def self.changed_fields(query, changes)
      Set.new(Change.ordered(changes).map { |field, _| Address.field(query.carrier, field) })
    end
    private_class_method :changed_fields

    # Refused rather than answered, and specifically not answered with the empty
    # set — which would be a claim that a scope dirties nothing, the one answer
    # that is certainly wrong.
    def self.refuse_scope!
      raise WritesError,
            'a scope does not say what it writes — its payload is a berylx workflow, a task tree, ' \
            'and what a task tree performs is not decidable from the value; union the writes of ' \
            'the operations composed inside it, because the empty set would claim the scope ' \
            'dirties nothing and that is the one answer certainly wrong'
    end
    private_class_method :refuse_scope!

    def self.refuse_tag!(tag)
      raise WritesError,
            "#{tag.inspect} is not one of the five operations, so nothing is known about what it " \
            "dirties — the operations are #{TAGS.inspect}"
    end
    private_class_method :refuse_tag!
  end
end
