# frozen_string_literal: true

require 'rack'

module Sodalite
  # The Rack app. Built once, frozen, and shared across every Puma thread:
  # routes, schemas, generated Data classes, and the handler map are all
  # immutable, and the only per-request state is one `Berylx::Root`.
  #
  #   app = Sodalite::App.new(
  #     routes:   [show_user, create_user],
  #     handlers: Sodalite::Effects.real(find_user: ->(id) { DB[id] }),
  #     errors:   { not_found: 404 })
  class App
    DEFAULT_MAX_BODY_BYTES = 1 << 20

    # Refused at the boundary: the request never becomes a Request, and no
    # task ever runs.
    Refusal = Data.define(:status, :code, :message, :violations) do
      def self.[](status, code, message, violations = [])
        new(status: status, code: code, message: message, violations: violations)
      end
    end
    private_constant :Refusal

    attr_reader :routes, :handlers

    # The assembled form: the routes, the capabilities they reach through, the
    # verbs the application invented, and the statuses it publishes for its own
    # error codes — in one place, because a service needs all four and used to
    # have to wire them together by hand.
    #
    #   Sodalite::App.build(
    #     routes:       ROUTES,
    #     capabilities: [Sodalite::DB.capability(db), Sodalite::Store.capability(objects)],
    #     effects:      { send_mail: Mailer.method(:deliver) },
    #     errors:       { not_found: 404, forbidden: 403 },
    #     world:        :real)
    def self.build(routes:, capabilities: [], effects: {}, errors: {}, world: :fixed, **)
      new(routes: routes, errors: errors,
          handlers: Effects.assemble(capabilities: capabilities, effects: effects, world: world),
          **)
    end

    def initialize(routes:, handlers: nil, errors: {}, max_body_bytes: DEFAULT_MAX_BODY_BYTES)
      @routes = Array(routes).freeze
      @router = Router.new(@routes)
      @handlers = handlers || Effects.real
      @max_body_bytes = max_body_bytes
      @performer = Berylx::Perform.new(@handlers)
      @render = Renderer.new(performer: @performer, errors: normalize_errors(errors))
      freeze
    end

    def call(env)
      verb = env['REQUEST_METHOD'].to_s
      case @router.match(verb, env['PATH_INFO'].to_s)
      in Router::Match[route:, params:]
        dispatch(route, params, env, head: verb == 'HEAD' && route.verb == 'GET')
      in Router::NotAllowed[allow:]
        verb == 'OPTIONS' ? [204, { 'allow' => allow }, []] : not_allowed(allow)
      else
        refuse(Refusal[404, :not_found, 'no route matches'])
      end
    end

    private

    def normalize_errors(errors)
      errors.to_h { |code, status| [code.to_sym, status] }.freeze
    end

    def dispatch(route, params, env, head:)
      sieved = sieve(route, params, env)
      return refuse(sieved) if sieved.is_a?(Refusal)

      result = Berylx::Root[request: sieved, response: nil].call(route.run, handlers: @handlers)
      case result
      when Berylx::Ok then @render.response(route, result.focus.to_h[:response], head: head)
      else @render.workflow_error(route, result)
      end
    end

    # ------------------------------------------------------------------
    # In: the sieve. Nothing past this point holds a value the schemas did
    # not admit, and every violation is reported at once, located by a
    # pointer that says which part of the request it came from.
    # ------------------------------------------------------------------
    def sieve(route, params, env)
      body = read_body(route, env)
      return body if body.is_a?(Refusal)

      path = route.params.load(params)
      query = route.query.load(query_of(env))
      violations = locate(path, '/params') + locate(query, '/query') + locate(body, '/body')
      return invalid(violations) unless violations.empty?

      build_request(env, path.value, query.value, body&.value)
    end

    def query_of(env)
      ::Rack::Utils.parse_query(env['QUERY_STRING'].to_s)
    end

    def locate(result, prefix)
      return [] if result.nil? || result.ok?

      result.violations.map { |violation| violation.with(path: "#{prefix}#{violation.path}") }
    end

    def read_body(route, env)
      return nil unless route.declares_body?

      type = env['CONTENT_TYPE'].to_s
      return unsupported_media(type) unless type.empty? || type.start_with?(JSON_TYPE)

      raw = env['rack.input']&.read(@max_body_bytes + 1).to_s
      return too_large if raw.bytesize > @max_body_bytes

      route.body.parse(raw)
    end

    def build_request(env, params, query, body)
      headers = Headers.from_env(env)
      Request.new(
        verb: env['REQUEST_METHOD'].to_s, path: env['PATH_INFO'].to_s,
        params: params, query: query, body: body, headers: headers,
        id: headers['x-request-id'] || @performer.perform(Effects::ID)
      )
    end

    # ------------------------------------------------------------------

    def refuse(refusal, headers = {})
      @render.failure(refusal.status, refusal.code, refusal.message,
                      violations: refusal.violations, headers: headers)
    end

    def not_allowed(allow)
      refuse(Refusal[405, :method_not_allowed, "allowed: #{allow}"], { 'allow' => allow })
    end

    def invalid(violations)
      Refusal[400, :invalid_request, 'request does not fit the declared shape', violations]
    end

    def unsupported_media(type)
      Refusal[415, :unsupported_media_type, "expected #{JSON_TYPE}, got #{type}"]
    end

    def too_large
      Refusal[413, :payload_too_large, "body exceeds #{@max_body_bytes} bytes"]
    end
  end
end
