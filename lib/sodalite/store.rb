# frozen_string_literal: true

require_relative '../sodalite'
require_relative 'store/journal'
require_relative 'store/memory'
require_relative 'store/filesystem'
require_relative 'store/s3'

module Sodalite
  # Object storage, given the same treatment as the database: a fixed signature,
  # several models, and a conformance check that they are the same store.
  #
  # The theory is smaller and worth stating exactly, because most of the bugs in
  # this area come from pretending it is bigger.
  #
  # A bucket is a **partial function** `Key ⇀ Object`. That is the whole data
  # model — no relations, no joins, no schema. The keys carry one piece of
  # structure: they form a **poset under the prefix order**, and `list(prefix)`
  # is the principal filter of that order, `{ k : prefix ≤ k }`. Prefix listing
  # is not a query language that happens to be weak; it is the only subobject the
  # order gives you.
  #
  #   PUT(key, bytes, meta)  -> key
  #   GET(key)               -> Object or nil     (partial, so nil is honest)
  #   DELETE(key)            -> boolean
  #   LIST(prefix)           -> keys, ordered
  #
  # **There are no transactions, and this does not pretend otherwise.** A store
  # cannot join `DB.atomically`; claiming it can is the classic distributed lie.
  # What `Store.saga` offers instead is compensation: a write registers its
  # inverse, and an `Err` in the surrounding scope runs the inverses in reverse.
  # That is *lax*: a delete after a put does not undo a read someone already did
  # in between. The name says saga rather than transaction for that reason.
  module Store
    PUT = :sodalite_store_put
    GET = :sodalite_store_get
    DELETE = :sodalite_store_delete
    LIST = :sodalite_store_list
    SAGA = :sodalite_store_saga

    TAGS = [PUT, GET, DELETE, LIST, SAGA].freeze

    class StoreError < StandardError; end

    # What a model hands back. `body` is bytes; `meta` is a small String map,
    # because the key set is the caller's and uncontrolled keys never become
    # Symbols — the same rule the HTTP boundary follows for headers.
    Object = Data.define(:key, :body, :meta) do
      def self.[](key, body, meta = {})
        new(key: key, body: body.b.freeze, meta: meta.freeze)
      end

      def size = body.bytesize

      # A stored JSON document can be read back through the same sieve that types
      # a request body, so "typed" does not stop at the HTTP edge.
      def typed(schema)
        schema.parse(body.dup.force_encoding(Encoding::UTF_8))
      end
    end

    module_function

    def memory(seed = {})
      Memory.new(seed)
    end

    def filesystem(root)
      Filesystem.new(root)
    end

    def s3(bucket, client)
      S3.new(bucket, client)
    end

    # A scope whose writes are undone by compensation rather than rollback.
    # Reads for it exactly like `DB.atomically`, and deliberately does not share
    # the name.
    def saga(name, workflow)
      Berylx::Task[name] do |lay, io|
        io.perform(SAGA, [workflow, lay])
      end
    end

    # A saga scope really is a handler-map swap — but the map has to be *built*
    # for the journal, not merged over an existing one. berylx warns about this
    # and it is easy to get wrong: the combinator handlers inside a finished map
    # close over the map they were constructed with, so a merged copy runs its
    # subtrees on the original bindings and the journal never sees a thing.
    #
    # So the scope rebuilds the map from the same inputs, with the journal in the
    # model's place. Nesting works because the rebuild is what recurses.
    def handlers(model, effects = {}, fixed: true, **options)
      store_effects = effects.merge(
        PUT => ->(payload) { model.put(payload[0], payload[1], payload[2] || {}) },
        GET => ->(key) { model.get(key) },
        DELETE => ->(key) { model.delete(key) },
        LIST => ->(prefix) { model.list(prefix.to_s) },
        SAGA => ->(payload) { run_saga(model, effects, payload, fixed: fixed, **options) }
      )
      fixed ? Effects.fixed(store_effects, **options) : Effects.real(store_effects, **options)
    end

    def run_saga(model, effects, payload, **)
      node, focus = payload
      journal = Journal.new(model)
      result = Berylx::EffectTree.run(node, focus, handlers: handlers(journal, effects, **))
      journal.compensate if result.is_a?(Berylx::Err)
      result
    end
  end
end
