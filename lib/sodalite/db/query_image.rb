# frozen_string_literal: true

module Sodalite
  module DB
    # What a projection closes. Image factorization makes a new object, and the
    # only maps out of it are the ones it kept — so what phase one may name
    # afterwards is decided here rather than by whichever model happens to be
    # answering. Left to the models it does not fail, it splits them: see
    # `test/db_image_closure_test.rb` for the four shapes and the four different
    # answers they used to give.
    module QueryImage
      # A projection makes a new object — the image — and a composition out of it
      # is not a composition in C. `author` is a morphism out of `posts`; after
      # `select(:author)` what is in hand is a set of tuples, and a tuple is not
      # an element of `posts` to compose from.
      #
      # Unchecked this does not even disagree quietly: the in-memory model
      # composes off the projected tuple and answers with whole rows of the
      # codomain, and both SQL models hand the database a statement it refuses
      # to parse.
      def check_composable!(operation)
        return unless image_fields

        raise QueryError,
              "#{operation} cannot come after select — the image is a set of tuples, " \
              'and a tuple is not an element to compose from'
      end

      # A projection keeps some maps out of the object and drops the rest, so the
      # image has only the ones it kept. Naming a dropped one afterwards is not a
      # subobject of the image; there is no such map to take one along. Widening
      # the projection to put it back is not the repair, for the same reason it
      # is not the repair for an order that lost its tiebreaker: the image is its
      # own object, and widening it answers a different question.
      #
      # Left unchecked this splits the models rather than failing. The in-memory
      # one filters the tuple it has already projected and finds the field gone;
      # both SQL models put the comparison in the `WHERE` of the very statement
      # that does the projecting, so they filter the object the image came from.
      def check_in_image!(field, operation)
        kept = image_fields
        return if kept.nil? || kept.include?(field.to_sym)

        raise QueryError,
              "#{operation} names #{carrier}.#{field}, which the projection #{kept.inspect} dropped — " \
              'the image is its own object, and the only maps out of it are the ones it kept'
      end

      # The projection in force at the carrier as it stands. A composition moves
      # the carrier to another object where the rows are whole again, so a select
      # taken before a hop says nothing about what may be named after it.
      def image_fields
        steps.reverse_each do |kind, *rest|
          return rest.first if kind == :select
          return nil if kind == :follow
        end
        nil
      end
    end
  end
end
