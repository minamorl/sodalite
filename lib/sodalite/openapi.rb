# frozen_string_literal: true

require_relative '../sodalite'
require_relative 'openapi/types'

module Sodalite
  # The document a service publishes, folded out of the routes it runs.
  #
  # Every route already carries its full declared shape — params, query, body,
  # and a schema per status — as ordinary data. So an OpenAPI document is a fold
  # over `app.routes`, not a second set of annotations to keep in sync with the
  # first. That is the whole point of declaring shapes instead of writing
  # validators: the contract cannot drift from the code, because it *is* the
  # code, read a different way.
  #
  #   Sodalite::OpenAPI.document(app, title: 'users', version: '1.0')
  #
  # What it will not do is invent. A refinement's predicate (`Zeolite.check`) is
  # a Ruby block and has no JSON Schema; it is reported as its base type with the
  # refinement's own label in `description`, rather than silently dropped or
  # silently guessed at.
  module OpenAPI
    PRIMITIVES = Types::PRIMITIVES

    module_function

    def document(app, title:, version:, servers: [])
      {
        'openapi' => '3.1.0',
        'info' => { 'title' => title, 'version' => version },
        'servers' => servers.map { |url| { 'url' => url } },
        'paths' => paths(app.routes)
      }.reject { |_key, value| value.respond_to?(:empty?) && value.empty? }
    end

    def paths(routes)
      routes.group_by { |route| openapi_path(route) }
            .transform_values { |grouped| grouped.to_h { |route| [route.verb.downcase, operation(route)] } }
    end

    # `/users/:id` is sodalite's spelling; `/users/{id}` is OpenAPI's.
    def openapi_path(route)
      "/#{route.segments.map { |kind, value| kind == :param ? "{#{value}}" : value }.join('/')}"
    end

    def operation(route)
      {
        'operationId' => route.name.to_s,
        'parameters' => parameters(route),
        'requestBody' => request_body(route),
        'responses' => responses(route)
      }.compact.reject { |_key, value| value.respond_to?(:empty?) && value.empty? }
    end

    def parameters(route)
      declared(route.params).map { |field, spec| parameter(field, spec, 'path') } +
        declared(route.query).map { |field, spec| parameter(field, spec, 'query') }
    end

    def parameter(field, spec, location)
      {
        'name' => field.to_s,
        'in' => location,
        # A path parameter is always required; the `?` suffix only means anything
        # for a query, where a key can genuinely be absent.
        'required' => location == 'path' || !optional?(spec),
        'schema' => schema_of(spec)
      }
    end

    def request_body(route)
      return nil unless route.declares_body?

      { 'required' => true, 'content' => { JSON_TYPE => { 'schema' => schema_of(route.body.spec) } } }
    end

    def responses(route)
      answered = route.responses.to_h do |status, schema|
        [status.to_s,
         { 'description' => 'ok', 'content' => { JSON_TYPE => { 'schema' => schema_of(schema.spec) } } }]
      end
      answered.merge(error_responses(route))
    end

    # The statuses the framework itself can produce for any route, published for
    # the same reason the successful shapes are: a client should not have to
    # discover them by being surprised.
    def error_responses(route)
      statuses = { '400' => 'the request does not fit the declared shape',
                   '404' => 'no route matches', '405' => 'method not allowed' }
      statuses['415'] = 'expected application/json' if route.declares_body?
      statuses['413'] = 'body too large' if route.declares_body?
      statuses.to_h do |status, description|
        [status, { 'description' => description,
                   'content' => { JSON_TYPE => { 'schema' => schema_of(Errors::SCHEMA.spec) } } }]
      end
    end

    # --- the declared vocabulary, mapped ------------------------------------

    def schema_of(spec)
      case spec
      when Symbol then primitive(spec)
      when Array then { 'type' => 'array', 'items' => schema_of(spec.first) }
      when Hash then object(spec)
      else typed(spec)
      end
    end

    def object(spec)
      required = spec.reject { |_field, inner| optional?(inner) }.keys.map(&:to_s)
      { 'type' => 'object',
        'properties' => spec.to_h { |field, inner| [field.to_s, schema_of(inner)] },
        'required' => required }.reject { |_key, value| value.respond_to?(:empty?) && value.empty? }
    end

    def primitive(spec)
      base = PRIMITIVES.fetch(spec.to_s.delete_suffix('?').to_sym, {})
      optional?(spec) ? base.merge('nullable' => true) : base
    end

    def typed(type)
      Types.typed(type)
    end

    def declared(text_schema)
      text_schema.schema.spec
    end

    def optional?(spec)
      spec.is_a?(Symbol) ? spec.to_s.end_with?('?') : spec.is_a?(Zeolite::Nilable)
    end
  end
end
