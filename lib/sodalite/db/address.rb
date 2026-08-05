# frozen_string_literal: true

module Sodalite
  module DB
    # A place in the instance that an answer can depend on.
    #
    # This exists so that "is this answer stale" can be decided without asking
    # the database and without the framework remembering anything. A query says
    # which addresses it reads; an operation says which it dirties; the two sets
    # either meet or they do not. Both are functions of values that were already
    # in hand — the arrow, and the payload the caller was going to perform — so
    # nothing here reads, and nothing here is stored.
    #
    # That is the whole reason it is a value rather than a subscription. A
    # registry of live subscriptions has to outlive a request and be written by
    # a different one, which is process-global mutable state; this framework
    # does not have any, and a channel is not a good enough reason to start. The
    # calculus is offered instead, and whoever wants a channel builds it from
    # these sets with a broker of their own.
    #
    # There are two kinds, and the split is the reason the calculus is worth
    # anything:
    #
    #   elements(:posts)        which elements the object has
    #   field(:posts, :title)   where a map sends them
    #
    # An insert or a delete changes which elements exist, and nothing else. An
    # update changes where a map sends them, and nothing else — it cannot make
    # an element appear or disappear. So an update to `posts.title` leaves a
    # query that only reads `posts.id` alone, which is the case a coarser scheme
    # gets wrong and the case that made this worth building.
    Address = Data.define(:object, :field) do
      # Which elements the object has. Read by any arrow over it, dirtied by
      # anything that adds or removes one.
      def self.elements(object)
        new(object: object.to_sym, field: nil)
      end

      # Where one map out of the object sends its elements. A foreign key and an
      # attribute are the same kind of thing here — both are maps out of the
      # object, and an answer depends on one exactly when it consults it.
      def self.field(object, field)
        new(object: object.to_sym, field: field.to_sym)
      end

      def elements?
        field.nil?
      end

      # A total order, so a set of addresses has one rendering and two of them
      # can be compared as text in a test failure. Elements sort before the maps
      # out of the same object, which is also the order they are explained in.
      def <=>(other)
        return nil unless other.is_a?(Address)

        [object.to_s, field.to_s] <=> [other.object.to_s, other.field.to_s]
      end

      include Comparable

      def to_s
        elements? ? object.to_s : "#{object}.#{field}"
      end

      alias_method :inspect, :to_s
    end
  end
end
