# frozen_string_literal: true

require 'fileutils'
require 'json'

module Sodalite
  module Store
    # A second real model, with real IO. It exists to be *different* — a
    # directory tree is not a Hash, so it disagrees about anything the signature
    # left vague, and the conformance suite finds those places instead of leaving
    # them to production.
    #
    # A key is not a path. `a/b` and `a%2Fb` are different keys and must stay
    # different objects, so keys are encoded rather than joined, and the prefix
    # order is computed on the *keys* rather than on the directory structure.
    class Filesystem
      def initialize(root)
        @root = root
        FileUtils.mkdir_p(@root)
      end

      def put(key, body, meta = {})
        path = path_for(key)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, body.b)
        File.binwrite("#{path}.meta", ::JSON.generate(stringify(meta)))
        key.to_s
      end

      def get(key)
        path = path_for(key)
        return nil unless File.exist?(path)

        Object[key.to_s, File.binread(path), read_meta(path)]
      end

      # Reports whether an object went, which is what S3's delete does not tell
      # you and what a caller usually wants to know.
      def delete(key) # rubocop:disable Naming/PredicateMethod
        path = path_for(key)
        return false unless File.exist?(path)

        FileUtils.rm_f(path)
        FileUtils.rm_f("#{path}.meta")
        true
      end

      def list(prefix = '')
        keys.select { |key| key.start_with?(prefix) }.sort
      end

      private

      def keys
        Dir.glob(File.join(@root, '*.blob')).map { |path| decode(File.basename(path, '.blob')) }
      end

      # One flat directory of encoded keys: a key containing `/` is one object,
      # not a directory, and the prefix order is a property of the key string.
      def path_for(key)
        File.join(@root, "#{encode(key.to_s)}.blob")
      end

      def encode(key)
        key.unpack1('H*')
      end

      def decode(name)
        [name].pack('H*').force_encoding(Encoding::UTF_8)
      end

      def read_meta(path)
        return {} unless File.exist?("#{path}.meta")

        ::JSON.parse(File.read("#{path}.meta"))
      end

      def stringify(meta)
        meta.to_h { |name, value| [name.to_s, value.to_s] }
      end
    end
  end
end
