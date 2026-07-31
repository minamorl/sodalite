# frozen_string_literal: true

require 'json'

module Sodalite
  # The sieve, in the other direction.
  #
  # What is checked here is the JSON the client will actually receive — not a
  # Hash that resembles it — so "typed on the way out" is literally true. A
  # response that does not fit the shape its route publishes is the service
  # breaking its own contract, and the contract handler decides what that
  # costs: a raise in tests, a logged 500 in production.
  class Renderer
    def initialize(performer:, errors: {})
      @performer = performer
      @errors = errors
      freeze
    end

    def response(route, response, head:)
      return no_response(route) if response.nil?
      return stream(route, response) if response.streaming?

      json = response.body.nil? ? nil : ::JSON.generate(response.body)
      checked = check(route, response.status, json)
      return checked if checked

      triple(response.status, json, response.headers, head: head)
    end

    def failure(status, code, message, violations: [], headers: {})
      triple(status, ::JSON.generate(Errors.body(code, message, violations)), headers)
    end

    # A named domain failure maps to the status the app declared for it.
    # Anything unmapped is a 500 whose message stays in the log: an error the
    # service never named is not one it meant to expose.
    def workflow_error(route, result)
      status = @errors.fetch(result.code, 500)
      log_failure(route, result)
      failure(status, result.code, status == 500 ? 'internal error' : result.message.to_s)
    end

    def breach(route, status, violations)
      @performer.perform(
        Effects::CONTRACT,
        Effects::Breach.new(route: label(route), status: status, violations: violations)
      )
      failure(500, :contract_breach, 'internal error')
    end

    private

    def check(route, status, json)
      schema = route.responses[status]
      return nil unless schema

      result = json.nil? ? missing_body : schema.parse(json)
      result.ok? ? nil : breach(route, status, result.violations)
    end

    # The headers are already on the wire by the time a record is rejected, so
    # there is no status left to change. The stream stops, and it stops loudly.
    def stream(route, response)
      body = StreamBody.new(response.stream, @performer) do |violations|
        @performer.perform(
          Effects::CONTRACT,
          Effects::Breach.new(route: label(route), status: response.status, violations: violations)
        )
      end
      [response.status, response.headers.merge('content-type' => response.stream.content_type), body]
    end

    def triple(status, json, headers, head: false)
      return [status, headers, []] if json.nil?

      [status,
       headers.merge('content-type' => JSON_TYPE, 'content-length' => json.bytesize.to_s),
       head ? [] : [json]]
    end

    def log_failure(route, result)
      @performer.perform(
        Effects::LOG,
        event: 'request_failed', route: label(route),
        code: result.code.to_s, message: result.message.to_s,
        failed_node: result.failed_node&.to_s, trace: Array(result.trace).map(&:to_s)
      )
    end

    def label(route)
      "#{route.verb} #{route.template}"
    end

    def violation(code, message)
      Zeolite::Violation['', code, message]
    end

    def no_response(route)
      breach(route, nil, [violation(:no_response, 'the route produced no response')])
    end

    def missing_body
      Zeolite::Err.new(
        violations: [violation(:missing_body, 'the status declares a shape but no body was produced')]
      )
    end
  end

  # Rack 3 asks a body only for `each`. The stream is pulled here, on the
  # server thread, one validated record at a time.
  class StreamBody
    include Enumerable

    def initialize(stream, performer, &on_violation)
      @stream = stream
      @performer = performer
      @on_violation = on_violation
    end

    def each(&)
      @stream.each(@performer, @on_violation, &)
    end
  end
end
