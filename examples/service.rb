# frozen_string_literal: true

# A complete zeolite-web service, and the same service run twice: once against
# a fixed world with no server at all, and once on Puma over a real socket.
#
#   ruby -Ilib examples/service.rb          # in-process, deterministic
#   ruby -Ilib examples/service.rb serve    # puma on 127.0.0.1:9292
#
# Nothing about the routes changes between the two. Only the handler map does.

require 'stringio'
require 'sodalite'

W = Sodalite

# --- the workflow: named steps over focused state -------------------------
# No step reaches for a database, a clock, or a random number. Each asks the
# handler map it is currently running under, by tag.

load_user = Berylx::Task[:load_user] do |lay, io|
  user = io.perform(:find_user, lay[:request].get.params.id)
  user ? lay[:user].set(user) : lay.reject(:not_found, "no user #{lay[:request].get.params.id}")
end

check_visible = Berylx::Task[:check_visible] do |lay|
  lay[:user].get[:hidden] ? lay.reject(:forbidden, 'this user is hidden') : lay
end

stamp = Berylx::Task[:stamp] do |lay, io|
  lay[:at].set(io.perform(W::Effects::CLOCK).iso8601)
end

present = Berylx::Task[:present] do |lay|
  user = lay[:user].get
  lay[:response].set(W.ok({ id: user[:id], name: user[:name], at: lay[:at].get }))
end

# --- the routes: shapes in, shapes out ------------------------------------

show_user = W::Route[
  :get, '/users/:id',
  params: { id: :integer },
  query: { loud: :boolean? },
  responses: { 200 => { id: :integer, name: :string, at: :string } },
  run: load_user >> check_visible >> stamp >> present
]

create_user = W::Route[
  :post, '/users',
  body: { name: Zeolite.sized(:string, min: 1, max: 64) },
  responses: { 201 => { id: :integer, name: :string } },
  run: Berylx::Task[:create_user] do |lay, io|
    created = io.perform(:insert_user, lay[:request].get.body.name)
    lay[:response].set(W.respond(201, { id: created[:id], name: created[:name] }))
  end
]

tail_events = W::Route[
  :get, '/events',
  responses: {},
  run: Berylx::Task[:tail_events] do |lay|
    lay[:response].set(
      W.stream(200, { seq: :integer, kind: Zeolite.enum(:tick, :done) }) do |emit, _io|
        3.times { |seq| emit.call({ seq: seq, kind: 'tick' }) }
        emit.call({ seq: 3, kind: 'done' })
      end
    )
  end
]

ROUTES = [show_user, create_user, tail_events].freeze
ERRORS = { not_found: 404, forbidden: 403 }.freeze

USERS = { 7 => { id: 7, name: 'mina' }, 8 => { id: 8, name: 'ghost', hidden: true } }.freeze

WORLD = {
  find_user: ->(id) { USERS[id] },
  insert_user: ->(name) { { id: 99, name: name } }
}.freeze

def build(handlers)
  Sodalite::App.new(routes: ROUTES, handlers: handlers, errors: ERRORS)
end

if ARGV.first == 'serve'
  require 'sodalite/server'
  Sodalite::Server.run(build(W::Effects.real(WORLD)), port: 9292)
else
  # The same app, the same routes, a world made of fixed values, and no socket.
  app = build(W::Effects.fixed(WORLD, now: Time.at(1_700_000_000).utc))

  def show(app, verb, path, query: '', body: nil)
    env = { 'REQUEST_METHOD' => verb, 'PATH_INFO' => path, 'QUERY_STRING' => query }
    if body
      env['rack.input'] = StringIO.new(body)
      env['CONTENT_TYPE'] = 'application/json'
    end
    status, _headers, chunks = app.call(env)
    puts "#{verb.ljust(6)} #{path.ljust(16)} -> #{status} #{chunks.to_a.join.strip}"
  end

  show(app, 'GET', '/users/7')
  show(app, 'GET', '/users/8')
  show(app, 'GET', '/users/9')
  show(app, 'GET', '/users/abc')
  show(app, 'POST', '/users', body: '{"name":"rin"}')
  show(app, 'POST', '/users', body: '{"name":""}')
  show(app, 'GET', '/events')
end
