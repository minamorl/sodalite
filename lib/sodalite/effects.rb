# frozen_string_literal: true

require 'json'
require 'securerandom'

module Sodalite
  # The framework performs its own IO through the same tagged effects it asks
  # of you. There is no `Time.now` and no `SecureRandom` reachable from a
  # request path except through a handler you supplied, which is what makes a
  # whole request reproducible without a clock, a database, or a socket.
  module Effects
    CLOCK = :sodalite_clock
    ID = :sodalite_id
    LOG = :sodalite_log
    CONTRACT = :sodalite_contract

    RESERVED = [CLOCK, ID, LOG, CONTRACT].freeze

    # What the CONTRACT handler is handed when a response does not fit the
    # shape the route publishes for that status.
    Breach = Data.define(:route, :status, :violations) do
      def to_s
        "#{route} responded #{status} outside its declared shape: #{violations.join('; ')}"
      end
    end

    class ContractError < StandardError; end

    module_function

    # Production: a real clock, real ids, JSON lines to `io`, and a contract
    # breach that is logged and turned into a 500 rather than shipped.
    def real(effects = {}, io: $stderr)
      build(defaults(io: io), effects)
    end

    # Tests and dry runs: a fixed clock, counted ids, log lines collected in
    # `log`, and a contract breach that raises — a service that drifts from
    # its published shape should fail the suite, not degrade in silence.
    def fixed(effects = {}, now: Time.at(0).utc, log: [])
      counter = 0
      mutex = Mutex.new
      build(
        {
          CLOCK => ->(_payload) { now },
          ID => ->(_payload) { mutex.synchronize { "test-#{counter += 1}" } },
          LOG => ->(entry) { mutex.synchronize { log << entry } },
          CONTRACT => ->(breach) { raise ContractError, breach.to_s }
        },
        effects
      )
    end

    def defaults(io: $stderr)
      {
        CLOCK => ->(_payload) { Time.now.utc },
        ID => ->(_payload) { SecureRandom.uuid },
        LOG => ->(entry) { io.write("#{::JSON.generate(entry)}\n") },
        CONTRACT => lambda { |breach|
          io.write("#{::JSON.generate(event: 'contract_breach', message: breach.to_s)}\n")
        }
      }
    end

    def build(base, effects)
      Berylx::EffectTree.real_handlers(base.merge(check(effects)))
    end

    # Wrap an interpreter so an aspect reaches into `parallel`, `branch`, and
    # `rescue` subtrees too. The routes are never rewritten to add one.
    def around(effects = {}, &)
      Berylx::EffectTree.around(defaults.merge(check(effects)), &)
    end

    # An application that took `:sodalite_clock` would silently unhook the
    # framework's own IO, so the collision is an error rather than a surprise.
    def check(effects)
      collisions = effects.keys & RESERVED
      return effects if collisions.empty?

      raise ArgumentError, "effect tags collide with sodalite tags: #{collisions.inspect}"
    end
  end
end
