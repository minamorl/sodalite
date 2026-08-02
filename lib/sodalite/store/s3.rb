# frozen_string_literal: true

module Sodalite
  module Store
    # S3, reached through a port small enough to read in one screen. The gem
    # depends on no AWS SDK: hand it anything answering these four, and
    # `Aws::S3::Client` already does.
    #
    #   put_object(bucket:, key:, body:, metadata:)
    #   get_object(bucket:, key:)                      -> #body, #metadata
    #   delete_object(bucket:, key:)
    #   list_objects_v2(bucket:, prefix:, continuation_token:)  -> #contents, #next_continuation_token
    #
    # **Unverified against real S3 in this repository.** The memory and
    # filesystem models are conformance-checked against each other; this one is
    # the same shape written against the SDK's signatures, and saying so is worth
    # more than a test that mocks the SDK and proves nothing.
    #
    # Two behaviours are S3's and are not smoothed over:
    #
    # - `list` paginates. The signature says a listing is the principal filter of
    #   the prefix order, so this drains the pages rather than handing back the
    #   first thousand and calling it the set.
    # - S3 is eventually consistent for some operations and offers no
    #   transactions. `Store.saga` compensates; it does not roll back.
    class S3
      def initialize(bucket, client)
        @bucket = bucket
        @client = client
      end

      def put(key, body, meta = {})
        @client.put_object(bucket: @bucket, key: key.to_s, body: body.b, metadata: stringify(meta))
        key.to_s
      end

      def get(key)
        response = @client.get_object(bucket: @bucket, key: key.to_s)
        Object[key.to_s, read(response.body), (response.metadata || {}).transform_keys(&:to_s)]
      rescue StandardError => e
        raise unless no_such_key?(e)

        nil
      end

      def delete(key) # rubocop:disable Naming/PredicateMethod
        return false if get(key).nil?

        @client.delete_object(bucket: @bucket, key: key.to_s)
        true
      end

      # A page is not the set. Drain until the continuation token runs out.
      def list(prefix = '')
        keys = []
        token = nil
        loop do
          page = @client.list_objects_v2(bucket: @bucket, prefix: prefix, continuation_token: token)
          keys.concat(page.contents.map(&:key))
          token = page.next_continuation_token
          break if token.nil? || token.empty?
        end
        keys.sort
      end

      private

      def read(body)
        body.respond_to?(:read) ? body.read : body.to_s
      end

      def no_such_key?(error)
        error.class.name.include?('NoSuchKey') || error.class.name.include?('NotFound')
      end

      def stringify(meta)
        meta.to_h { |name, value| [name.to_s, value.to_s] }
      end
    end
  end
end
