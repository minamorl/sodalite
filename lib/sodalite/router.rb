# frozen_string_literal: true

require 'rack'

module Sodalite
  # A segment trie built once, at boot, and frozen. Matching walks it with
  # static segments preferred over parameters and backtracks when a longer
  # static path turns out to be a dead end.
  #
  # Every ambiguity is a build error, never a runtime coin flip: two routes
  # that could both answer the same request, or two different parameter names
  # in the same position, raise before the server binds a port.
  class Router
    class ConflictError < StandardError; end

    Match = Data.define(:route, :params)
    NotAllowed = Data.define(:allow)
    NoRoute = Data.define

    NO_ROUTE = NoRoute.new.freeze

    class Node
      attr_reader :static, :routes
      attr_accessor :param_name, :param_node

      def initialize
        @static = {}
        @routes = {}
        @param_name = nil
        @param_node = nil
      end
    end

    private_constant :Node

    def initialize(routes)
      @root = Node.new
      Array(routes).each { |route| insert(route) }
      freeze
    end

    def match(verb, path)
      found = descend(@root, split(path), 0, {})
      return NO_ROUTE unless found

      node, params = found
      route = node.routes[verb] || (verb == 'HEAD' ? node.routes['GET'] : nil)
      return Match.new(route: route, params: params) if route

      NotAllowed.new(allow: allow_header(node))
    end

    private

    # Split first, unescape second. Doing it the other way round lets a
    # percent-encoded slash in a parameter invent a path separator.
    def split(path)
      path.split('/').reject(&:empty?).map { |segment| Rack::Utils.unescape_path(segment) }
    end

    def descend(node, segments, index, params)
      return (node.routes.empty? ? nil : [node, params]) if index == segments.size

      segment = segments[index]
      if (child = node.static[segment])
        found = descend(child, segments, index + 1, params)
        return found if found
      end
      return nil unless node.param_node

      descend(node.param_node, segments, index + 1, params.merge(node.param_name.to_s => segment))
    end

    def insert(route)
      node = route.segments.reduce(@root) { |current, (kind, value)| step(current, kind, value, route) }
      existing = node.routes[route.verb]
      if existing
        raise ConflictError,
              "#{route.verb} #{route.template} conflicts with #{existing.verb} #{existing.template}"
      end

      node.routes[route.verb] = route
    end

    def step(node, kind, value, route)
      return node.static[value] ||= Node.new if kind == :static

      if node.param_name && node.param_name != value
        raise ConflictError,
              "#{route.template} names a parameter :#{value} where :#{node.param_name} is already declared"
      end

      node.param_name = value
      node.param_node ||= Node.new
    end

    # HEAD is answered by the GET route, so it belongs in Allow even when no
    # one declared it.
    def allow_header(node)
      verbs = node.routes.keys
      verbs += ['HEAD'] if verbs.include?('GET') && !verbs.include?('HEAD')
      (verbs + ['OPTIONS']).uniq.join(', ')
    end
  end
end
