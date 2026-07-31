# frozen_string_literal: true

module Sodalite
  module Store
    # Compensation does not belong to any one model, so it is not written three
    # times. A journal wraps *any* store, records the inverse of each write by
    # reading what was there first, and replays the inverses backwards.
    #
    # A saga scope is therefore a handler-map swap: the subtree runs on a map
    # whose store tags point at the journal instead of the store. That is the
    # same mechanism as everything else in this framework, used once more.
    #
    # It is lax, and the laxness is the honest part. `put` then compensating
    # `delete` does not undo a `get` someone already did in between, and no
    # object store gives you a way to make it. That is why this is called a saga
    # and shares no vocabulary with `DB.atomically`.
    class Journal
      def initialize(store)
        @store = store
        @undo = []
      end

      def put(key, body, meta = {})
        @undo << inverse_of_write(key.to_s)
        @store.put(key, body, meta)
      end

      def delete(key)
        @undo << inverse_of_write(key.to_s)
        @store.delete(key)
      end

      def get(key) = @store.get(key)
      def list(prefix = '') = @store.list(prefix)

      def compensate
        @undo.reverse_each(&:call)
        @undo.clear
      end

      private

      # Read before writing: whatever was there is what restores it, and if
      # nothing was there the inverse is a delete.
      def inverse_of_write(key)
        existing = @store.get(key)
        return -> { @store.delete(key) } if existing.nil?

        -> { @store.put(key, existing.body, existing.meta) }
      end
    end
  end
end
