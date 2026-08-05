# frozen_string_literal: true

require 'test_helper'

# The sieve already reads NDJSON and SSE one record at a time. A framework built
# on it writes them the same way, and validates each record as it goes.
class StreamTest < Minitest::Test
  include Sodalite::TestSupport

  CHUNK = { seq: :integer, text: :string }.freeze

  def stream_route(framing: :ndjson, records: [{ seq: 1, text: 'a' }, { seq: 2, text: 'b' }])
    run = Berylx::Task[:tail] do |lay|
      lay[:response].set(
        Sodalite.stream(200, CHUNK, framing: framing) do |emit, _io|
          records.each { |record| emit.call(record) }
        end
      )
    end
    Sodalite::Route[:get, '/tail', responses: { 200 => CHUNK }, run: run]
  end

  def drain(triple)
    triple[2].to_enum(:each).to_a
  end

  def test_ndjson_records_are_framed_one_per_line
    triple = app(stream_route).call(env(:get, '/tail'))

    assert_equal 'application/x-ndjson', triple[1]['content-type']
    assert_equal ["{\"seq\":1,\"text\":\"a\"}\n", "{\"seq\":2,\"text\":\"b\"}\n"], drain(triple)
  end

  def test_sse_uses_the_data_framing
    triple = app(stream_route(framing: :sse)).call(env(:get, '/tail'))

    assert_equal 'text/event-stream', triple[1]['content-type']
    assert_equal ["data: {\"seq\":1,\"text\":\"a\"}\n\n", "data: {\"seq\":2,\"text\":\"b\"}\n\n"], drain(triple)
  end

  # The status line is already on the wire, so there is no status left to
  # change. The stream stops at the bad record, and it stops loudly.
  def test_a_record_outside_the_declared_shape_stops_the_stream_loudly
    route = stream_route(records: [{ seq: 1, text: 'a' }, { seq: 'two', text: 'b' }, { seq: 3, text: 'c' }])
    triple = app(route).call(env(:get, '/tail'))

    error = assert_raises(Sodalite::Effects::ContractError) { drain(triple) }

    assert_match(%r{/seq: expected integer}, error.message)
  end

  def test_a_producer_can_perform_effects_while_streaming
    run = Berylx::Task[:tail] do |lay|
      lay[:response].set(
        Sodalite.stream(200, CHUNK) do |emit, io|
          io.perform(:rows).each { |row| emit.call(row) }
        end
      )
    end
    route = Sodalite::Route[:get, '/tail', responses: { 200 => CHUNK }, run: run]
    handlers = Sodalite::Effects.fixed({ rows: ->(_payload) { [{ seq: 9, text: 'z' }] } })

    triple = Sodalite::App.new(routes: [route], handlers: handlers).call(env(:get, '/tail'))

    assert_equal ["{\"seq\":9,\"text\":\"z\"}\n"], drain(triple)
  end
end

# Two verbs the framework answers without being asked to, because getting them
# wrong is the kind of thing that shows up in someone else's proxy.
class ProtocolTest < Minitest::Test
  include Sodalite::TestSupport

  def user_app
    run = Berylx::Task[:present] { |lay| lay[:response].set(Sodalite.ok({ id: 1 })) }
    app(Sodalite::Route[:get, '/users', responses: { 200 => { id: :integer } }, run: run])
  end

  def test_head_runs_the_get_route_and_returns_its_length_without_its_body
    head = user_app.call(env(:head, '/users'))
    get = user_app.call(env(:get, '/users'))

    assert_equal 200, head[0]
    assert_equal get[1]['content-length'], head[1]['content-length']
    assert_empty head[2]
  end

  def test_options_answers_with_allow_rather_than_refusing
    triple = user_app.call(env(:options, '/users'))

    assert_equal 204, triple[0]
    assert_equal 'GET, HEAD, OPTIONS', triple[1]['allow']
  end

  def test_a_wrong_verb_is_refused_with_allow
    triple = user_app.call(env(:delete, '/users'))

    assert_equal 405, triple[0]
    assert_equal 'GET, HEAD, OPTIONS', triple[1]['allow']
  end
end
