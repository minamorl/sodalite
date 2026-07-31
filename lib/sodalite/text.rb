# frozen_string_literal: true

module Sodalite
  # A URL carries no types. A JSON document does.
  #
  # The sieve refuses to guess across JSON types on purpose: `"1"` is not an
  # `Integer`, because a document that wrote `"1"` had `1` available and did not
  # use it. A path segment or a query value carries no such evidence — every
  # value is text — so *declaring* the type is the only way to have one.
  #
  # Two different worlds, so two different vocabularies. Text sources get one
  # explicit decode step before the sieve, and the sieve's no-coercion rule
  # stays exactly as strict as it was for JSON bodies.
  #
  # A value that does not decode is passed through **unchanged**, so the schema
  # — not this file — produces the violation, with the right pointer and code.
  # There is one error path, not two.
  class TextSchema
    MISS = Object.new.freeze
    private_constant :MISS

    IDENTITY = ->(value) { value }

    # Each decoder answers "what JSON value did this text denote?", or MISS.
    DECODERS = {
      string: IDENTITY,
      any: IDENTITY,
      # `:time` is parsed by the sieve itself, from the String, so it stays text.
      time: IDENTITY,
      integer: ->(text) { Integer(text, 10, exception: false) || MISS },
      float: ->(text) { Float(text, exception: false) || MISS },
      number: ->(text) { Float(text, exception: false) || MISS },
      boolean: lambda { |text|
        case text
        when 'true'  then true
        when 'false' then false
        else MISS
        end
      }
    }.freeze

    attr_reader :schema, :keys

    def initialize(spec, strict: false)
      raise Zeolite::SchemaError, 'a text schema describes an object of declared keys' unless spec.is_a?(Hash)

      schema = Zeolite.schema(spec)
      @schema = strict ? schema.strict : schema
      @decoders = spec.to_h { |key, field| [key.to_s, self.class.decoder_for(field)] }.freeze
      @keys = spec.keys.map(&:to_sym).freeze
      freeze
    end

    def empty?
      @decoders.empty?
    end

    # `raw` is what the transport handed over: String values, or Arrays of
    # String where the source repeats a key.
    def load(raw)
      document = {}
      raw.each do |key, text|
        decoder = @decoders[key]
        document[key] = decoder ? decoder.call(text) : text
      end
      @schema.load(document)
    end

    def self.decoder_for(field)
      case field
      when Array  then array_decoder(field.first)
      when Symbol then leaf_decoder(field)
      else IDENTITY
      end
    end

    # A repeated key arrives as an Array; a single occurrence of a field
    # declared as an array is one-element, which is a decode decision and so
    # belongs here rather than in the schema.
    def self.array_decoder(element)
      inner = decoder_for(element)
      ->(value) { Array(value).map { |text| inner.call(text) } }
    end

    def self.leaf_decoder(name)
      decode = DECODERS.fetch(name.to_s.delete_suffix('?').to_sym, IDENTITY)
      lambda do |text|
        next text unless text.is_a?(String)

        decoded = decode.call(text)
        decoded.equal?(MISS) ? text : decoded
      end
    end

    private_class_method :array_decoder, :leaf_decoder
  end
end
