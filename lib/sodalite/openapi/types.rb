# frozen_string_literal: true

module Sodalite
  module OpenAPI
    # Zeolite's own type objects, mapped one constructor at a time. Everything
    # here is read from what the schema *declared*; nothing is inferred from
    # behaviour, and a predicate — which is a Ruby block with no JSON Schema —
    # publishes its label rather than a wider contract than the service accepts.
    module Types
      PRIMITIVES = {
        string: { 'type' => 'string' },
        integer: { 'type' => 'integer' },
        float: { 'type' => 'number' },
        number: { 'type' => 'number' },
        boolean: { 'type' => 'boolean' },
        null: { 'type' => 'null' },
        time: { 'type' => 'string', 'format' => 'date-time' },
        any: {}
      }.freeze

      # One entry per constructor zeolite offers, so a new one is a missing entry
      # rather than a silently untyped field.
      MAPPINGS = {
        Zeolite::Enum => ->(type, _of) { { 'type' => 'string', 'enum' => type.values.map(&:to_s) } },
        Zeolite::Literal => ->(type, _of) { { 'const' => type.value } },
        Zeolite::OneOf => lambda { |type, emit|
          { 'oneOf' => type.alternatives.map do |inner|
            emit.call(inner)
          end }
        },
        Zeolite::ArrayOf => ->(type, emit) { { 'type' => 'array', 'items' => emit.call(type.inner) } },
        Zeolite::MapOf => lambda { |type, emit|
          { 'type' => 'object', 'additionalProperties' => emit.call(type.inner) }
        },
        Zeolite::Nilable => ->(type, emit) { emit.call(type.inner).merge('nullable' => true) },
        Zeolite::Prim => ->(type, _of) { PRIMITIVES.fetch(type.name, {}) },
        Zeolite::Refined => ->(type, emit) { emit.call(type.inner).merge('description' => type.label) },
        Zeolite::Record => ->(type, emit) { Types.record(type, emit) }
      }.freeze

      module_function

      def typed(type)
        mapping = MAPPINGS.find { |constructor, _emit| type.is_a?(constructor) }
        return {} unless mapping

        mapping.last.call(type, method(:typed))
      end

      def record(type, emit)
        { 'type' => 'object',
          'properties' => type.fields.to_h { |field, inner| [field.to_s, emit.call(inner)] },
          'required' => type.fields.reject { |_field, inner| inner.optional? }.keys.map(&:to_s) }
      end
    end
  end
end
