# frozen_string_literal: true

require 'test_helper'

# What the berylx + darkcore axis buys, stated as tests: the world is a
# parameter, a failure keeps its state, and an aspect is a handler swap.
class SubstrateTest < Minitest::Test
  include Sodalite::TestSupport

  LOAD = Berylx::Task[:load_user] do |lay, io|
    user = io.perform(:find_user, lay[:request].get.params.id)
    user ? lay[:user].set(user) : lay.reject(:not_found, 'no such user')
  end

  STAMP = Berylx::Task[:stamp] do |lay, io|
    lay[:seen_at].set(io.perform(Sodalite::Effects::CLOCK).iso8601)
  end

  PRESENT = Berylx::Task[:present] do |lay|
    lay[:response].set(
      Sodalite.ok({ id: lay[:user].get[:id], seen_at: lay[:seen_at].get, request_id: lay[:request].get.id })
    )
  end

  RESPONSES = { 200 => { id: :integer, seen_at: :string, request_id: :string } }.freeze

  def user_route(run: LOAD >> STAMP >> PRESENT)
    Sodalite::Route[:get, '/users/:id', params: { id: :integer }, responses: RESPONSES, run: run]
  end

  DEFAULT_FIND = ->(id) { id == 7 ? { id: 7 } : nil }

  def find_user(&block)
    { find_user: block || DEFAULT_FIND }
  end

  # No database, no clock, no uuid generator: the same route, the same router,
  # the same sieve, and a world made of fixed values.
  def test_the_whole_request_is_reproducible_from_fixed_handlers
    triples = Array.new(2) do
      Sodalite::App.new(
        routes: [user_route],
        handlers: Sodalite::Effects.fixed(find_user, now: Time.at(1_700_000_000).utc)
      ).call(env(:get, '/users/7'))
    end

    assert_equal triples[0], triples[1]
    assert_equal '2023-11-14T22:13:20Z', json_body(triples[0])['seen_at']
    assert_equal 'test-1', json_body(triples[0])['request_id']
  end

  def test_a_client_supplied_request_id_is_kept_so_a_trace_survives_the_boundary
    triple = app([user_route], handlers: Sodalite::Effects.fixed(find_user))
             .call(env(:get, '/users/7', headers: { 'x-request-id' => 'abc-123' }))

    assert_equal 'abc-123', json_body(triple)['request_id']
  end

  # A domain failure keeps the state it reached and the name of the task that
  # produced it. The client sees the mapped status; the log sees the trace.
  def test_a_domain_failure_maps_to_a_status_and_logs_the_named_task
    log = []
    triple = Sodalite::App.new(
      routes: [user_route],
      handlers: Sodalite::Effects.fixed(find_user, log: log),
      errors: { not_found: 404 }
    ).call(env(:get, '/users/9'))

    assert_equal 404, triple[0]
    assert_equal 'not_found', json_body(triple)['error']['code']
    assert_equal 'load_user', log.last[:failed_node]
  end

  # An error the service never named is not one it meant to expose, so it is a
  # 500 and its message does not leak.
  def test_an_unmapped_failure_is_a_500_that_does_not_leak_its_message
    triple = Sodalite::App.new(
      routes: [user_route],
      handlers: Sodalite::Effects.fixed(find_user { |_id| raise 'connection refused to 10.0.0.4' })
    ).call(env(:get, '/users/7'))

    assert_equal 500, triple[0]
    assert_equal 'internal error', json_body(triple)['error']['message']
    refute_includes triple[2].join, '10.0.0.4'
  end

  # The route is never rewritten to be observed. `around` wraps the interpreter,
  # and the wrapped map is what the subtrees run on too.
  def test_an_aspect_observes_every_task_without_touching_the_route
    seen = []
    handlers = Sodalite::Effects.around(find_user) do |tag, payload, inner|
      seen << payload.first.name if tag == Berylx::EffectTree::TASK
      inner.call(payload)
    end

    triple = Sodalite::App.new(routes: [user_route], handlers: handlers).call(env(:get, '/users/7'))

    assert_equal 200, triple[0]
    assert_equal %i[load_user stamp present], seen
  end

  def test_framework_effect_tags_cannot_be_taken_by_an_application
    error = assert_raises(ArgumentError) do
      Sodalite::Effects.fixed({ Sodalite::Effects::CLOCK => ->(_) { Time.now } })
    end

    assert_match(/collide with sodalite tags/, error.message)
  end

  def test_parallel_branches_share_the_frozen_handler_map
    left = Berylx::Task[:left] { |lay, io| lay[:left].set(io.perform(:find_user, 7)) }
    right = Berylx::Task[:right] { |lay, io| lay[:right].set(io.perform(:find_user, 7)) }
    present = Berylx::Task[:present] do |lay|
      Berylx::Result.ok(lay[:response].set(Sodalite.ok({ id: lay[:left].get[:id] + lay[:right].get[:id] })))
    end
    route = Sodalite::Route[:get, '/pair', responses: { 200 => { id: :integer } },
                                           run: (left & right) >> present]

    triple = Sodalite::App.new(routes: [route], handlers: Sodalite::Effects.fixed(find_user))
                          .call(env(:get, '/pair'))

    assert_equal 200, triple[0]
    assert_equal 14, json_body(triple)['id']
  end
end
