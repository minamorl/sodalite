# frozen_string_literal: true

# The bundled puma boot, with the settings this framework's concurrency story
# assumes: threads over processes, because the app is frozen at boot and shared.

require_relative 'app'
require 'sodalite/server'

Sodalite::Server.run(Service.app(world: :real), port: Integer(ENV.fetch('PORT', 9292)))
