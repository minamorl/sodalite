# frozen_string_literal: true

require 'test_helper'

# Everything checkable about a route is checked when the route is built, not on
# the first request that happens to exercise it.
class RouteTest < Minitest::Test
  include Sodalite::TestSupport

  NOOP = Berylx::Task[:noop] { |lay| lay }

  def test_declared_params_must_match_the_template
    error = assert_raises(Sodalite::RouteError) do
      Sodalite::Route[:get, '/users/:id', params: { user_id: :integer }, run: NOOP]
    end

    assert_match(/template params \[:id\] do not match declared params \[:user_id\]/, error.message)
  end

  def test_an_undeclared_template_param_is_a_build_error
    assert_raises(Sodalite::RouteError) { Sodalite::Route[:get, '/users/:id', run: NOOP] }
  end

  def test_an_unknown_verb_is_a_build_error
    assert_raises(Sodalite::RouteError) { Sodalite::Route[:fetch, '/users', run: NOOP] }
  end

  def test_a_template_must_be_rooted
    assert_raises(Sodalite::RouteError) { Sodalite::Route[:get, 'users', run: NOOP] }
  end

  # berylx is asked at boot whether it can compile this node.
  def test_a_run_that_is_not_a_berylx_node_is_a_build_error
    assert_raises(Sodalite::RouteError) { Sodalite::Route[:get, '/users', run: -> { :nope }] }
  end

  def test_a_non_integer_response_status_is_a_build_error
    assert_raises(Sodalite::RouteError) do
      Sodalite::Route[:get, '/users', responses: { ok: { id: :integer } }, run: NOOP]
    end
  end
end

# A URL carries no types, so text sources declare theirs. What does not decode
# is passed through unchanged, so the schema reports the violation with the
# right pointer and code — one error path, not two.
class TextSchemaTest < Minitest::Test
  include Sodalite::TestSupport

  def load(spec, raw)
    Sodalite::TextSchema.new(spec).load(raw)
  end

  def test_declared_primitives_are_decoded_from_text
    value = load({ n: :integer, f: :float, b: :boolean, s: :string },
                 { 'n' => '42', 'f' => '0.5', 'b' => 'false', 's' => '7' }).value

    assert_equal 42, value.n
    assert_in_delta 0.5, value.f
    refute value.b
    assert_equal '7', value.s
  end

  def test_text_that_does_not_decode_becomes_a_schema_violation
    result = load({ n: :integer }, { 'n' => 'twelve' })

    assert_predicate result, :err?
    assert_equal :type_mismatch, result.violations.first.code
    assert_equal '/n', result.violations.first.path
  end

  def test_an_absent_optional_key_is_nil_and_an_absent_required_key_is_a_violation
    assert_nil load({ n: :integer? }, {}).value.n
    assert_equal :missing_key, load({ n: :integer }, {}).violations.first.code
  end

  def test_a_repeated_key_and_a_single_occurrence_both_fit_an_array_field
    assert_equal [1, 2], load({ ids: [:integer] }, { 'ids' => %w[1 2] }).value.ids
    assert_equal [1], load({ ids: [:integer] }, { 'ids' => '1' }).value.ids
  end

  # An enum still owns the only door from document text to a Symbol, and it can
  # only emit symbols the schema already named.
  def test_an_enum_over_text_stays_closed
    spec = { order: Zeolite.enum(:asc, :desc) }

    assert_equal :desc, load(spec, { 'order' => 'desc' }).value.order
    assert_equal :not_in_enum, load(spec, { 'order' => 'sideways' }).violations.first.code
  end

  def test_undeclared_keys_are_dropped_by_default
    assert_predicate load({ n: :integer }, { 'n' => '1', 'utm' => 'x' }), :ok?
  end
end
