# frozen_string_literal: true

require 'json'

module Sodalite
  JSON_TYPE = 'application/json'
  NDJSON_TYPE = 'application/x-ndjson'
  SSE_TYPE = 'text/event-stream'

  # What a task produces. `body` is a plain Ruby value; it is checked against
  # the status's declared response schema on the way out, so a service cannot
  # quietly drift from the shape it publishes.
  Response = Data.define(:status, :headers, :body, :stream) do
    def self.[](status, body = nil, headers: {})
      new(status: status, headers: headers, body: body, stream: nil)
    end

    def streaming?
      !stream.nil?
    end
  end

  # A response the sieve writes on the way out, one record at a time, in the
  # same two framings it reads on the way in. Records are validated
  # individually, so a malformed record is caught at the record — not after
  # the whole body was already generated, and not after it was already sent.
  class Stream
    FRAMINGS = {
      ndjson: [NDJSON_TYPE, ->(json) { "#{json}\n" }],
      sse: [SSE_TYPE, ->(json) { "data: #{json}\n\n" }]
    }.freeze

    attr_reader :schema, :framing, :content_type

    def initialize(schema, framing: :ndjson, &producer)
      raise ArgumentError, 'a stream needs a producer block' unless producer
      raise ArgumentError, "unknown framing #{framing.inspect}" unless FRAMINGS.key?(framing)

      @schema = schema.is_a?(Zeolite::Schema) ? schema : Zeolite.schema(schema)
      @framing = framing
      @content_type, @frame = FRAMINGS.fetch(framing)
      @producer = producer
      freeze
    end

    # `on_violation` is how a broken record reaches the contract handler. The
    # headers are already on the wire by then, so there is no status left to
    # change: the stream stops, and it stops loudly.
    def each(performer, on_violation)
      emit = lambda do |record|
        json = ::JSON.generate(record)
        check = @schema.parse(json)
        throw :zeolite_stream_broken, on_violation.call(check.violations) unless check.ok?

        yield @frame.call(json)
      end
      catch(:zeolite_stream_broken) { @producer.call(emit, performer) }
    end
  end

  module_function

  def respond(status, body = nil, headers: {})
    Response[status, body, headers: headers]
  end

  def ok(body = nil, headers: {})
    Response[200, body, headers: headers]
  end

  def created(body = nil, headers: {})
    Response[201, body, headers: headers]
  end

  def no_content(headers: {})
    Response[204, nil, headers: headers]
  end

  # `Web.stream(200, Chunk) { |emit, io| ... emit.call(record) }`
  def stream(status, schema, framing: :ndjson, headers: {}, &producer)
    Response.new(status: status, headers: headers, body: nil,
                 stream: Stream.new(schema, framing: framing, &producer))
  end
end
