# frozen_string_literal: true

require 'zeolite'
require 'berylx'

require_relative 'sodalite/version'
require_relative 'sodalite/text'
require_relative 'sodalite/request'
require_relative 'sodalite/response'
require_relative 'sodalite/errors'
require_relative 'sodalite/effects'
require_relative 'sodalite/route'
require_relative 'sodalite/router'
require_relative 'sodalite/render'
require_relative 'sodalite/app'
require_relative 'sodalite/health'

# Sodalite is a web framework where the request is a value, the world is a
# parameter, and nothing untyped gets in or out.
#
#   puma      transport: sockets, a thread pool, graceful shutdown
#   zeolite   in:  declared shape -> generated Data, or 400 with every violation
#   berylx    the route is a composition of named tasks over focused state
#   darkcore  every effect is a tagged value; the handler map is the world
#   zeolite   out: the JSON the client will receive, checked against what the route publishes
#
# Four properties fall out, and they are the whole pitch:
#
# 1. The request is a value. The Rack env never reaches your code.
# 2. The world is a parameter. Swap the handler map and the same route runs
#    against a real database or against fixed values, with no mocks.
# 3. Failure keeps its state. `Err(partial_lay, error)` says which named task
#    failed, with what state, so compensation has something to work with.
# 4. Cross-cutting is a handler swap, not a callback chain. No `before_action`,
#    no middleware stack rewriting your route.
#
# In mineralogy the *sodalite cage* is the structural unit that zeolite
# frameworks are assembled from. That is the whole relationship: this is the
# framework built on the sieve, and it depends on `zeolite` as an ordinary gem
# rather than living inside it.
#
# `require 'sodalite/server'` separately for the bundled Puma boot; the app
# itself is a plain Rack app and does not depend on being served by it.
module Sodalite
end
