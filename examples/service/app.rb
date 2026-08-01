# frozen_string_literal: true

# A complete service, assembled the way a real one is: routes, a database, an
# object store, the verbs the application invented, and the statuses it publishes
# for its own error codes.
#
#   ruby -Ilib examples/service/app.rb          # against a fixed world, no server
#   ruby -Ilib examples/service/app.rb openapi  # the document, from the routes
#   rackup examples/service/config.ru           # or any Rack server
#   ruby -Ilib examples/service/boot.rb         # puma, with the bundled defaults

require 'sodalite/db'
require 'sodalite/store'
require 'sodalite/openapi'

module Service
  SCHEMA = Sodalite::DB.schema(
    users: { id: :integer, name: :string, city: :string },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  # Named arrows. Not effects — values, built once and reused.
  BY_CITY = ->(city) { SCHEMA[:users].where(:city, city).order(:name) }
  BUSIEST = SCHEMA[:posts].follow(:author).group(:city).count(:people).order(:people, :desc)

  # --- the workflow -------------------------------------------------------
  # No step reaches for a database handle, a clock, or a socket. Each asks the
  # handler map it is currently running under, by tag.

  load_user = Berylx::Task[:load_user] do |lay, io|
    found = io.perform(Sodalite::DB::SELECT, SCHEMA[:users].where(:id, lay[:request].get.params.id))
    if found.empty?
      lay.reject(:not_found,
                 "no user #{lay[:request].get.params.id}")
    else
      lay[:user].set(found.rows.first)
    end
  end

  attach_avatar = Berylx::Task[:attach_avatar] do |lay, io|
    lay[:avatar].set(!io.perform(Sodalite::Store::GET, "avatars/#{lay[:user].get[:id]}").nil?)
  end

  present_user = Berylx::Task[:present_user] do |lay|
    user = lay[:user].get
    lay[:response].set(Sodalite.ok({ id: user[:id], name: user[:name], avatar: lay[:avatar].get }))
  end

  # A saga, not a transaction: the object store cannot join one, and the name
  # says so. If the row insert fails, the uploaded avatar is taken back.
  publish_avatar = Sodalite::Store.saga(
    :publish_avatar,
    Berylx::Task[:upload] do |lay, io|
      io.perform(Sodalite::Store::PUT, ["avatars/#{lay[:request].get.params.id}", lay[:request].get.body.png])
      lay
    end >>
      Berylx::Task[:announce] do |lay, io|
        io.perform(:send_mail, "avatar for #{lay[:request].get.params.id}")
        lay[:response].set(Sodalite.respond(201, { stored: true }))
      end
  )

  ROUTES = [
    Sodalite::Route[:get, '/users/:id',
                    params: { id: :integer },
                    responses: { 200 => { id: :integer, name: :string, avatar: :boolean } },
                    run: load_user >> attach_avatar >> present_user,
                    name: :show_user],

    Sodalite::Route[:put, '/users/:id/avatar',
                    params: { id: :integer },
                    body: { png: Zeolite.sized(:string, min: 1) },
                    responses: { 201 => { stored: :boolean } },
                    run: publish_avatar,
                    name: :put_avatar],

    Sodalite::Route[:get, '/cities/:city/users',
                    params: { city: :string },
                    query: { limit: :integer? },
                    responses: { 200 => { names: [:string] } },
                    run: Berylx::Task[:by_city] do |lay, io|
                      found = io.perform(Sodalite::DB::SELECT, BY_CITY.call(lay[:request].get.params.city))
                      lay[:response].set(Sodalite.ok({ names: found.map { |row| row[:name] } }))
                    end,
                    name: :users_by_city],

    Sodalite::Route[:get, '/stats/busiest-cities',
                    responses: { 200 => { cities: [{ city: :string, people: :integer }] } },
                    run: Berylx::Task[:busiest] do |lay, io|
                      found = io.perform(Sodalite::DB::SELECT, BUSIEST)
                      lay[:response].set(Sodalite.ok({ cities: found.map(&:to_h) }))
                    end,
                    name: :busiest_cities],

    Sodalite.health,
    Sodalite.health(path: '/ready', checks: {
                      database: ->(io) { io.perform(Sodalite::DB::SELECT, SCHEMA[:users]) },
                      objects: ->(io) { io.perform(Sodalite::Store::LIST, '') }
                    })
  ].freeze

  ERRORS = { not_found: 404, forbidden: 403, conflict: 409 }.freeze

  SEED = {
    users: [{ id: 1, name: 'mina', city: 'tokyo' }, { id: 2, name: 'rin', city: 'osaka' },
            { id: 3, name: 'ghost', city: 'tokyo' }],
    posts: [{ id: 10, title: 'hello', author: 1 }, { id: 11, title: 'again', author: 1 },
            { id: 12, title: 'hi', author: 2 }]
  }.freeze

  module_function

  # The whole assembly, in one place. Swap what `capabilities` and `world` are
  # and the same service runs against real infrastructure or against fixed
  # values — the routes do not know which.
  def app(db: Sodalite::DB.memory(SCHEMA, SEED), objects: Sodalite::Store.memory, world: :fixed)
    Sodalite::App.build(
      routes: ROUTES,
      capabilities: [Sodalite::DB.capability(db), Sodalite::Store.capability(objects)],
      effects: { send_mail: ->(subject) { subject } },
      errors: ERRORS,
      world: world
    )
  end
end

if $PROGRAM_NAME == __FILE__
  require 'json'
  require 'stringio'

  if ARGV.first == 'openapi'
    puts JSON.pretty_generate(Sodalite::OpenAPI.document(Service.app, title: 'service', version: '1.0'))
  else
    service = Service.app
    [%w[GET /users/1], %w[GET /users/9], %w[GET /users/abc], %w[GET /cities/tokyo/users],
     %w[GET /stats/busiest-cities], %w[GET /health], %w[GET /ready]].each do |verb, path|
      status, _headers, chunks = service.call('REQUEST_METHOD' => verb, 'PATH_INFO' => path,
                                              'QUERY_STRING' => '')
      puts "#{verb.ljust(4)} #{path.ljust(24)} -> #{status} #{chunks.to_a.join.strip}"
    end
  end
end
