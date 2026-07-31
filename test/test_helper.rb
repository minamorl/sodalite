# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'stringio'
require 'sodalite'

module Sodalite
  module TestSupport
    def env(verb, path, query: '', body: nil, headers: {})
      base = {
        'REQUEST_METHOD' => verb.to_s.upcase,
        'PATH_INFO' => path,
        'QUERY_STRING' => query
      }
      base['rack.input'] = StringIO.new(body) if body
      base['CONTENT_TYPE'] = headers.delete('content-type') || 'application/json' if body
      headers.each { |name, value| base["HTTP_#{name.upcase.tr('-', '_')}"] = value }
      base
    end

    def json_body(triple)
      JSON.parse(triple[2].join)
    end

    def app(routes, handlers: nil, errors: {}, log: [])
      Sodalite::App.new(
        routes: Array(routes),
        handlers: handlers || Sodalite::Effects.fixed(log: log),
        errors: errors
      )
    end
  end
end
