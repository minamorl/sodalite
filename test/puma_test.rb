# frozen_string_literal: true

require 'test_helper'

require 'sodalite/server'
require 'net/http'

# The axis end to end: a real socket, a real Puma thread pool, and the same app
# object every unit test above drove directly.
class PumaTest < Minitest::Test
  include Sodalite::TestSupport

  BOOT_TIMEOUT = 10

  def setup
    @port = free_port
    @launcher = Sodalite::Server.launcher(built_app, port: @port, quiet: true)
    @thread = Thread.new { @launcher.run }
    wait_for_boot
  end

  def teardown
    @launcher&.stop
    @thread&.join(BOOT_TIMEOUT)
  end

  def test_a_fitting_request_round_trips_over_http
    response = get('/users/7?loud=true')

    assert_equal '200', response.code
    assert_equal 'application/json', response['content-type']
    assert_equal({ 'id' => 7, 'name' => 'MINA' }, JSON.parse(response.body))
  end

  def test_a_request_that_does_not_fit_is_refused_at_the_boundary
    response = get('/users/abc')

    assert_equal '400', response.code
    assert_equal '/params/id', JSON.parse(response.body)['violations'].first['path']
  end

  def test_a_domain_failure_arrives_as_its_mapped_status
    assert_equal '404', get('/users/9').code
  end

  def test_a_stream_arrives_record_by_record
    lines = []
    Net::HTTP.start('127.0.0.1', @port) do |http|
      http.request(Net::HTTP::Get.new('/tail')) do |response|
        assert_equal 'application/x-ndjson', response['content-type']
        response.read_body { |chunk| lines << chunk }
      end
    end

    assert_equal([{ 'seq' => 1 }, { 'seq' => 2 }], lines.join.lines.map { |line| JSON.parse(line) })
  end

  # The gem that reads NDJSON reads back what it wrote, over a real socket.
  def test_the_sieve_reads_back_the_stream_it_wrote
    feed = Zeolite.feed(Zeolite.schema(seq: :integer))
    results = []
    Net::HTTP.start('127.0.0.1', @port) do |http|
      http.request(Net::HTTP::Get.new('/tail')) do |response|
        response.read_body { |bytes| feed.push(bytes) { |result| results << result } }
      end
    end
    feed.finish { |result| results << result }

    assert(results.all?(&:ok?))
    assert_equal([1, 2], results.map { |result| result.value.seq })
  end

  private

  def get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}#{path}"))
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_boot
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    loop do
      TCPSocket.new('127.0.0.1', @port).close
      return
    rescue SystemCallError
      raise 'puma did not boot' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def built_app
    Sodalite::App.new(
      routes: [user_route, tail_route],
      handlers: Sodalite::Effects.fixed({ find_user: ->(id) { id == 7 ? { id: 7, name: 'mina' } : nil } }),
      errors: { not_found: 404 }
    )
  end

  def user_route
    load_user = Berylx::Task[:load_user] do |lay, io|
      user = io.perform(:find_user, lay[:request].get.params.id)
      user ? lay[:user].set(user) : lay.reject(:not_found, 'no such user')
    end
    present = Berylx::Task[:present] do |lay|
      user = lay[:user].get
      name = lay[:request].get.query.loud ? user[:name].upcase : user[:name]
      lay[:response].set(Sodalite.ok({ id: user[:id], name: name }))
    end

    Sodalite::Route[:get, '/users/:id',
                    params: { id: :integer }, query: { loud: :boolean? },
                    responses: { 200 => { id: :integer, name: :string } },
                    run: load_user >> present]
  end

  def tail_route
    tail = Berylx::Task[:tail] do |lay|
      lay[:response].set(
        Sodalite.stream(200, { seq: :integer }) do |emit, _io|
          [1, 2].each { |seq| emit.call({ seq: seq }) }
        end
      )
    end

    Sodalite::Route[:get, '/tail', responses: { 200 => { seq: :integer } }, run: tail]
  end
end
