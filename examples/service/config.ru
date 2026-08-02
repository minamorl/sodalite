# frozen_string_literal: true

# The service as an ordinary Rack app: `rackup examples/service/config.ru`.
# Nothing about the routes changes between this and the bundled puma boot — only
# which world the capabilities are built against.

require_relative 'app'

run Service.app(world: :real)
