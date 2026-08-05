# frozen_string_literal: true

require 'test_helper'

# The boundary in both directions: what a request must look like to reach a
# task at all, and what a response must look like to leave.
class SieveTest < Minitest::Test
  include Sodalite::TestSupport

  ECHO = proc do |lay|
    request = lay[:request].get
    lay[:response].set(
      Sodalite.ok({ id: request.params.id, page: request.query.page, name: request.body&.name })
    )
  end

  def show_route(verb: :get, **overrides)
    Sodalite::Route[
      verb, '/users/:id',
      params: { id: :integer }, query: { page: :integer? },
      responses: { 200 => { id: :integer, page: :integer?, name: :string? } },
      run: Berylx::Task[:echo, &ECHO], **overrides
    ]
  end

  def test_a_fitting_request_reaches_the_task_as_typed_data
    triple = app(show_route).call(env(:get, '/users/7', query: 'page=2'))

    assert_equal 200, triple[0]
    assert_equal({ 'id' => 7, 'page' => 2, 'name' => nil }, json_body(triple))
  end

  # Every violation, from every part of the request, located by a pointer that
  # says which part it came from.
  def test_violations_are_exhaustive_and_say_where_they_came_from
    triple = app(show_route).call(env(:get, '/users/abc', query: 'page=xyz'))
    paths = json_body(triple)['violations'].map { |violation| violation['path'] }

    assert_equal 400, triple[0]
    assert_equal ['/params/id', '/query/page'], paths.sort
  end

  def test_an_absent_optional_query_value_is_nil_not_a_violation
    triple = app(show_route).call(env(:get, '/users/7'))

    assert_equal 200, triple[0]
    assert_nil json_body(triple)['page']
  end

  def test_an_undeclared_query_key_is_dropped_rather_than_rejected
    triple = app(show_route).call(env(:get, '/users/7', query: 'page=1&utm_source=ads'))

    assert_equal 200, triple[0]
  end

  def test_a_body_is_parsed_by_the_same_sieve
    route = show_route(verb: :post, body: { name: :string })
    triple = app(route).call(env(:post, '/users/7', body: '{"name":"mina"}'))

    assert_equal 200, triple[0]
    assert_equal 'mina', json_body(triple)['name']
  end

  def test_a_malformed_body_is_a_located_violation_not_a_crash
    route = show_route(verb: :post, body: { name: :string })
    triple = app(route).call(env(:post, '/users/7', body: '{"name":'))

    assert_equal 400, triple[0]
    assert_equal 'invalid_json', json_body(triple)['violations'].first['code']
  end

  def test_a_non_json_content_type_is_refused_before_parsing
    route = show_route(verb: :post, body: { name: :string })
    triple = app(route).call(env(:post, '/users/7', body: 'name=mina',
                                                    headers: { 'content-type' => 'application/x-www-form-urlencoded' }))

    assert_equal 415, triple[0]
  end

  def test_an_oversized_body_is_refused_before_parsing
    route = show_route(verb: :post, body: { name: :string })
    small = Sodalite::App.new(routes: [route], handlers: Sodalite::Effects.fixed, max_body_bytes: 8)
    triple = small.call(env(:post, '/users/7', body: JSON.generate(name: 'x' * 64)))

    assert_equal 413, triple[0]
    assert_equal 'payload_too_large', json_body(triple)['error']['code']
  end

  # The way out is the same sieve. What gets validated is the JSON the client
  # will actually receive, so a service cannot drift from what it publishes.
  def test_a_response_outside_its_declared_shape_is_a_contract_breach
    drift = Berylx::Task[:drift] { |lay| lay[:response].set(Sodalite.ok({ id: 'seven' })) }
    route = show_route(run: drift)

    error = assert_raises(Sodalite::Effects::ContractError) { app(route).call(env(:get, '/users/7')) }

    assert_match(%r{/id: expected integer}, error.message)
  end

  def test_a_route_that_produces_no_response_is_a_contract_breach
    silent = Berylx::Task[:silent] { |lay| lay }
    route = show_route(run: silent)

    error = assert_raises(Sodalite::Effects::ContractError) { app(route).call(env(:get, '/users/7')) }

    assert_match(/no_response/, error.message)
  end

  def test_a_response_with_an_undeclared_status_is_a_contract_breach
    teapot = Berylx::Task[:teapot] do |lay|
      lay[:response].set(Sodalite.respond(418, { whatever: 'x' }))
    end
    route = show_route(run: teapot)

    error = assert_raises(Sodalite::Effects::ContractError) { app(route).call(env(:get, '/users/7')) }

    assert_match(/undeclared_status/, error.message)
  end

  def test_an_undeclared_status_becomes_a_logged_500_in_the_real_world
    require 'stringio'

    io = StringIO.new
    teapot = Berylx::Task[:teapot] do |lay|
      lay[:response].set(Sodalite.respond(418, { whatever: 'x' }))
    end
    route = show_route(run: teapot)
    triple = Sodalite::App.new(routes: [route], handlers: Sodalite::Effects.real(io: io))
                          .call(env(:get, '/users/7'))

    assert_equal 500, triple[0]
    assert_includes io.string, 'undeclared_status'
  end

  def test_a_declared_error_shape_checks_the_error_body_the_framework_will_send
    reject = Berylx::Task[:reject] { |lay| lay.reject(:missing, 'nope') }
    route = show_route(responses: { 200 => { id: :integer }, 404 => { totally: :string } }, run: reject)
    broken = app(route, errors: { missing: 404 })

    error = assert_raises(Sodalite::Effects::ContractError) { broken.call(env(:get, '/users/7')) }

    assert_match(%r{/totally}, error.message)
  end

  def test_a_framework_400_uses_the_framework_error_contract_when_the_route_does_not_declare_it
    triple = app(show_route).call(env(:get, '/users/not-an-integer'))

    assert_equal 400, triple[0]
    assert_predicate Sodalite::Errors::SCHEMA.parse(triple[2].join), :ok?
  end

  def test_the_error_body_fits_the_declared_error_schema
    triple = app(show_route).call(env(:get, '/users/abc'))

    assert_predicate Sodalite::Errors::SCHEMA.parse(triple[2].join), :ok?
  end
end
