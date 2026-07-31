# frozen_string_literal: true

require 'test_helper'

class RouterTest < Minitest::Test
  include Sodalite::TestSupport

  def stub_task
    Berylx::Task[:noop] { |lay| lay }
  end

  def build(*templates)
    routes = templates.map do |verb, template, params|
      Sodalite::Route[verb, template, params: params || {}, run: stub_task]
    end
    Sodalite::Router.new(routes)
  end

  def test_static_segment_wins_over_a_parameter
    router = build(%w[GET /users/me], [:get, '/users/:id', { id: :string }])

    assert_equal '/users/me', router.match('GET', '/users/me').route.template
    assert_equal '/users/:id', router.match('GET', '/users/7').route.template
  end

  # A longer static prefix that dead-ends must not shadow a parameter route
  # that would have matched.
  def test_matching_backtracks_out_of_a_static_dead_end
    router = build(
      [:get, '/a/b/c'],
      [:get, '/a/:x', { x: :string }]
    )

    match = router.match('GET', '/a/b')

    assert_equal '/a/:x', match.route.template
    assert_equal({ 'x' => 'b' }, match.params)
  end

  def test_duplicate_route_is_a_build_error
    error = assert_raises(Sodalite::Router::ConflictError) { build(%w[GET /users], %w[GET /users]) }

    assert_match(/conflicts with/, error.message)
  end

  def test_two_parameter_names_in_one_position_is_a_build_error
    error = assert_raises(Sodalite::Router::ConflictError) do
      build([:get, '/users/:id', { id: :string }], [:post, '/users/:slug', { slug: :string }])
    end

    assert_match(/:slug where :id is already declared/, error.message)
  end

  def test_unmatched_path_is_no_route_and_wrong_verb_is_not_allowed
    router = build(%w[GET /users])

    assert_instance_of Sodalite::Router::NoRoute, router.match('GET', '/nope')
    assert_equal 'GET, HEAD, OPTIONS', router.match('POST', '/users').allow
  end

  def test_head_is_answered_by_the_get_route
    router = build(%w[GET /users])

    assert_equal '/users', router.match('HEAD', '/users').route.template
  end

  # Split first, unescape second: a percent-encoded slash is data inside one
  # segment, not a separator that invents a path.
  def test_percent_encoded_slash_stays_inside_its_segment
    router = build([:get, '/files/:name', { name: :string }])

    match = router.match('GET', '/files/a%2Fb')

    assert_equal({ 'name' => 'a/b' }, match.params)
    assert_instance_of Sodalite::Router::NoRoute, router.match('GET', '/files/a/b')
  end

  def test_trailing_slash_matches_the_same_route
    router = build(%w[GET /users])

    assert_equal '/users', router.match('GET', '/users/').route.template
  end
end
