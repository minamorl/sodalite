# frozen_string_literal: true

module Sodalite
  # What a task actually receives. The Rack env does not come with it.
  #
  # `params`, `query`, and `body` are generated `Data` instances — real
  # readers, frozen, pattern-matchable — because they came through the sieve.
  # `headers` stays a `Hash[String, String]`: the key set is the client's, not
  # yours, and uncontrolled keys never become Symbols.
  Request = Data.define(:verb, :path, :params, :query, :body, :headers, :id) do
    def header(name)
      headers[name.to_s.downcase]
    end

    def content_type
      header('content-type')
    end
  end

  module Headers
    module_function

    SKIP = %w[HTTP_VERSION].freeze

    # `HTTP_ACCEPT_LANGUAGE` is `accept-language`. Content-Type and
    # Content-Length arrive without the prefix, so they are lifted by name.
    LIFTED = { 'CONTENT_TYPE' => 'content-type', 'CONTENT_LENGTH' => 'content-length' }.freeze

    def from_env(env)
      headers = {}
      env.each do |key, value|
        name = header_name(key)
        headers[name] = value.to_s if name
      end
      headers.freeze
    end

    def header_name(key)
      return nil unless key.is_a?(String)
      return LIFTED[key] if LIFTED.key?(key)
      return nil unless key.start_with?('HTTP_') && !SKIP.include?(key)

      key.delete_prefix('HTTP_').downcase.tr('_', '-')
    end
  end
end
