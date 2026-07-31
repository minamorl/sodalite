# frozen_string_literal: true

module Sodalite
  module Store
    # The partial function itself, as a Hash. Nothing is simulated here — this is
    # what the theory says a bucket is, so it is also the model the others are
    # checked against.
    class Memory
      def initialize(seed = {})
        @objects = {}
        @lock = Mutex.new
        seed.each { |key, body| put(key, body) }
      end

      def put(key, body, meta = {})
        @lock.synchronize { @objects[key.to_s] = Object[key.to_s, body, stringify(meta)] }
        key.to_s
      end

      def get(key)
        @objects[key.to_s]
      end

      def delete(key)
        @lock.synchronize { !@objects.delete(key.to_s).nil? }
      end

      # The principal filter of the prefix order, in key order — so that two
      # models cannot disagree about which listing they mean.
      def list(prefix = '')
        @objects.keys.select { |key| key.start_with?(prefix) }.sort
      end

      private

      def stringify(meta)
        meta.to_h { |name, value| [name.to_s, value.to_s] }
      end
    end
  end
end
