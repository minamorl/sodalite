# frozen_string_literal: true

require 'puma'
require 'puma/configuration'
require 'puma/launcher'
require 'puma/events'

module Sodalite
  # Puma, with the settings this framework's concurrency story assumes, and
  # nothing else. There is no per-request framework state to drain, so a
  # graceful shutdown is exactly Puma's: stop accepting, let in-flight
  # requests finish, exit.
  #
  # Threads, not processes: the app object is frozen at boot and shared, so
  # workers would buy copies of immutable data and lose a shared handler map.
  # If a handler you supply is not thread-safe, that is the one thing this
  # framework cannot check for you.
  module Server
    DEFAULT_THREADS = (5..5)

    module_function

    def configuration(app, host: '127.0.0.1', port: 9292, threads: DEFAULT_THREADS, **options)
      ::Puma::Configuration.new(options) do |config|
        config.app(app)
        config.bind("tcp://#{host}:#{port}")
        config.threads(threads.first, threads.last)
        config.environment('production')
      end
    end

    def launcher(app, events: ::Puma::Events.new, quiet: false, **)
      launcher_args = { events: events }
      launcher_args[:log_writer] = ::Puma::LogWriter.null if quiet
      ::Puma::Launcher.new(configuration(app, **), **launcher_args)
    end

    def run(app, **)
      launcher(app, **).run
    end
  end
end
