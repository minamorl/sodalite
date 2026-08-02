# frozen_string_literal: true

module Sodalite
  # Liveness and readiness, which are two different questions and are treated as
  # two.
  #
  # **Liveness** is framework-level: the process is up and its app answers. That
  # is a static route, and it is the one this can build for you.
  #
  # **Readiness** is not. Only the service knows what it needs before it should
  # be sent traffic, so the checks are declared, one lambda per dependency, each
  # given the performer so it asks through the same handler map as everything
  # else — which means readiness is reproducible in a test too.
  #
  #   Sodalite.health(path: '/ready', checks: {
  #     database: ->(io) { io.perform(Sodalite::DB::SELECT, HEARTBEAT) },
  #     objects:  ->(io) { io.perform(Sodalite::Store::LIST, '') }
  #   })
  #
  # A check that returns falsy or raises is down, and any down check makes the
  # whole answer 503 — a readiness endpoint that reports 200 with a broken
  # dependency is worse than not having one.
  module Health
    SHAPE = { status: :string, at: :string, checks: Zeolite.map_of(:string) }.freeze
    UP = 'up'
    DOWN = 'down'

    module_function

    def route(path: '/health', checks: {}, name: nil)
      Route[:get, path, name: name || :"health_#{path.tr('/', '_')}",
                        responses: { 200 => SHAPE, 503 => SHAPE },
                        run: probe(checks)]
    end

    def probe(checks)
      Berylx::Task[:health] do |lay, io|
        results = checks.to_h { |dependency, check| [dependency.to_s, run_check(check, io)] }
        down = results.value?(DOWN)
        lay[:response].set(
          Sodalite.respond(down ? 503 : 200,
                           { status: down ? DOWN : UP, at: io.perform(Effects::CLOCK).iso8601,
                             checks: results })
        )
      end
    end

    # A dependency that raises is down, not a 500: the endpoint exists to report
    # that, so letting the exception out would defeat it.
    def run_check(check, performer)
      check.call(performer) ? UP : DOWN
    rescue StandardError
      DOWN
    end
  end

  module_function

  def health(path: '/health', checks: {}, name: nil)
    Health.route(path: path, checks: checks, name: name)
  end
end
