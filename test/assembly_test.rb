# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'
require 'sodalite/store'
require 'sodalite/openapi'

# A real service reaches a database *and* an object store *and* whatever verbs it
# invented. Each capability used to build a whole handler map of its own, so you
# could have exactly one of them — this is the composition they were missing.
class AssemblyTest < Minitest::Test
  include Sodalite::TestSupport

  SCHEMA = Sodalite::DB.schema(users: { id: :integer, name: :string })

  def assembled(db: Sodalite::DB.memory(SCHEMA), objects: Sodalite::Store.memory, effects: {})
    [db, objects,
     Sodalite::Effects.assemble(
       capabilities: [Sodalite::DB.capability(db), Sodalite::Store.capability(objects)],
       effects: effects
     )]
  end

  def test_one_map_carries_every_capability_and_the_application_verbs
    _db, _objects, handlers = assembled(effects: { send_mail: ->(to) { to } })

    assert handlers.key?(Sodalite::DB::SELECT)
    assert handlers.key?(Sodalite::DB::UPDATE)
    assert handlers.key?(Sodalite::Store::PUT)
    assert handlers.key?(:send_mail)
    assert handlers.key?(Sodalite::Effects::CLOCK)
  end

  # A saga has to rebuild the map with the store journalled. Rebuilding, not
  # merging — so the other capabilities have to survive the rebuild.
  def test_a_saga_scope_keeps_the_other_capabilities
    db, objects, handlers = assembled
    db.insert(:users, { id: 1, name: 'mina' })
    seen = []

    workflow = Sodalite::Store.saga(
      :publish,
      Berylx::Task[:write] { |lay, io| io.perform(Sodalite::Store::PUT, %w[k v]) && lay } >>
        Berylx::Task[:read] { |lay, io| seen << io.perform(Sodalite::DB::SELECT, SCHEMA[:users]).size and lay } >>
        Berylx::Task[:fail] { |lay| lay.reject(:conflict, 'no') }
    )
    Berylx::Root[].call(workflow, handlers: handlers)

    assert_equal [1], seen
    assert_nil objects.get('k')
  end

  def test_a_transaction_scope_keeps_the_other_capabilities
    db, objects, handlers = assembled

    workflow = Sodalite::DB.atomically(
      :write,
      Berylx::Task[:row] { |lay, io| io.perform(Sodalite::DB::INSERT, [:users, { id: 1, name: 'a' }]) && lay } >>
        Berylx::Task[:blob] { |lay, io| io.perform(Sodalite::Store::PUT, %w[k v]) && lay } >>
        Berylx::Task[:fail] { |lay| lay.reject(:conflict, 'no') }
    )
    Berylx::Root[].call(workflow, handlers: handlers)

    assert_empty db.rows(:users)
    # The store is not in the transaction and does not pretend to be: the blob
    # stays, because only a saga would have taken it back.
    refute_nil objects.get('k')
  end

  def test_the_assembled_app_answers_a_request_through_both_capabilities
    db = Sodalite::DB.memory(SCHEMA, users: [{ id: 1, name: 'mina' }])
    objects = Sodalite::Store.memory('avatars/1' => 'png')
    route = Sodalite::Route[
      :get, '/users/:id',
      params: { id: :integer },
      responses: { 200 => { name: :string, avatar: :boolean } },
      run: Berylx::Task[:show] do |lay, io|
        id = lay[:request].get.params.id
        found = io.perform(Sodalite::DB::SELECT, SCHEMA[:users].where(:id, id)).rows.first
        lay[:response].set(
          Sodalite.ok({ name: found[:name], avatar: !io.perform(Sodalite::Store::GET, "avatars/#{id}").nil? })
        )
      end
    ]

    app = Sodalite::App.build(
      routes: [route],
      capabilities: [Sodalite::DB.capability(db), Sodalite::Store.capability(objects)]
    )

    assert_equal({ 'name' => 'mina', 'avatar' => true }, json_body(app.call(env(:get, '/users/1'))))
  end
end

# Liveness and readiness are two questions, so they are two routes.
class HealthTest < Minitest::Test
  include Sodalite::TestSupport

  def test_liveness_answers_without_any_dependency
    triple = app(Sodalite.health).call(env(:get, '/health'))

    assert_equal 200, triple[0]
    assert_equal 'up', json_body(triple)['status']
    assert_equal '1970-01-01T00:00:00Z', json_body(triple)['at']
  end

  def test_readiness_reports_each_dependency_by_name
    route = Sodalite.health(path: '/ready', checks: { database: ->(_io) { true }, objects: ->(_io) { true } })

    triple = app(route).call(env(:get, '/ready'))

    assert_equal 200, triple[0]
    assert_equal({ 'database' => 'up', 'objects' => 'up' }, json_body(triple)['checks'])
  end

  # A readiness endpoint that reports 200 with a broken dependency is worse than
  # not having one.
  def test_any_dependency_down_makes_the_whole_answer_unavailable
    route = Sodalite.health(path: '/ready', checks: { database: ->(_io) { true }, objects: ->(_io) { false } })

    triple = app(route).call(env(:get, '/ready'))

    assert_equal 503, triple[0]
    assert_equal 'down', json_body(triple)['status']
    assert_equal({ 'database' => 'up', 'objects' => 'down' }, json_body(triple)['checks'])
  end

  # The endpoint exists to report a broken dependency, so letting the exception
  # out would defeat it.
  def test_a_dependency_that_raises_is_down_not_an_internal_error
    route = Sodalite.health(path: '/ready', checks: { database: ->(_io) { raise 'connection refused' } })

    triple = app(route).call(env(:get, '/ready'))

    assert_equal 503, triple[0]
    assert_equal 'down', json_body(triple)['checks']['database']
    refute_includes triple[2].join, 'connection refused'
  end
end
