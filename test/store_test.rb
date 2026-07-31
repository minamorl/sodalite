# frozen_string_literal: true

require 'test_helper'
require 'sodalite/store'
require 'tmpdir'
require 'delegate'

# A bucket is a partial function `Key -> Object` whose keys carry one piece of
# structure: the prefix order. Two models, checked against each other, because a
# directory tree is not a Hash and will disagree wherever the signature was
# vague.
class StoreConformanceTest < Minitest::Test
  OPERATIONS = {
    'a key that was never written is absent' => ->(m) { m.get('nothing').inspect },
    'a written key reads back' => ->(m) { m.put('k', 'v') && m.get('k').body },
    'metadata survives the round trip' => ->(m) { m.put('k', 'v', size: 1) && m.get('k').meta },
    'a rewrite replaces' => ->(m) { m.put('k', 'one') && m.put('k', 'two') && m.get('k').body },
    'delete reports whether anything went' => ->(m) { [m.put('k', 'v') && m.delete('k'), m.delete('k')] },
    'listing is the principal filter of the prefix order' => lambda { |m|
      m.put('a/b', '1')
      m.put('a/c', '2')
      m.put('b/d', '3')
      [m.list('a/'), m.list('a'), m.list(''), m.list('zz')]
    },
    # A key is not a path. `a/b` is one object, not a directory containing b.
    'a slash in a key is data, not a directory' => lambda { |m|
      m.put('a/b', 'nested')
      m.put('a', 'flat')
      [m.get('a').body, m.get('a/b').body, m.list('a')]
    },
    'a key that looks encoded stays distinct' => lambda { |m|
      m.put('a/b', 'slash')
      m.put('a%2Fb', 'encoded')
      [m.get('a/b').body, m.get('a%2Fb').body]
    },
    'bytes survive intact' => lambda { |m|
      m.put('k', "\x00\xff\x01binary".b)
      m.get('k').body.bytes
    },
    'utf-8 keys and bodies survive' => lambda { |m|
      m.put('鍵/結衣', 'こんにちは')
      [m.list('鍵/'), m.get('鍵/結衣').body.dup.force_encoding(Encoding::UTF_8)]
    },
    'an empty body is an object, not an absence' => lambda { |m|
      m.put('k', '')
      [m.get('k').size, m.get('k').nil?]
    }
  }.freeze

  OPERATIONS.each do |label, operation|
    define_method("test_the_models_agree_on_#{label.tr(' ', '_').tr(',.`', '')}") do
      Dir.mktmpdir do |dir|
        assert_equal operation.call(Sodalite::Store.memory),
                     operation.call(Sodalite::Store.filesystem(dir)), label
      end
    end
  end

  # A stored JSON document reads back through the same sieve that types a
  # request body: the type discipline does not stop at the HTTP edge.
  def test_a_stored_document_reads_back_typed
    schema = Zeolite.schema(id: :integer, name: :string)
    store = Sodalite::Store.memory
    store.put('users/1.json', '{"id":1,"name":"mina"}')

    parsed = store.get('users/1.json').typed(schema)

    assert_predicate parsed, :ok?
    assert_equal 'mina', parsed.value.name
  end
end

# There are no transactions here, and the design does not pretend otherwise.
# Compensation is a handler-map swap, and it is lax on purpose.
class StoreSagaTest < Minitest::Test
  def write_two(fail_after:)
    first = Berylx::Task[:first] do |lay, io|
      io.perform(Sodalite::Store::PUT, %w[a new])
      lay
    end
    second = Berylx::Task[:second] do |lay, io|
      io.perform(Sodalite::Store::PUT, %w[b overwritten])
      fail_after ? lay.reject(:conflict, 'no') : lay
    end
    Sodalite::Store.saga(:write, first >> second)
  end

  def seeded
    Sodalite::Store.memory('b' => 'original')
  end

  def test_a_successful_scope_keeps_its_writes
    store = seeded
    result = Berylx::Root[].call(write_two(fail_after: false), handlers: Sodalite::Store.handlers(store))

    assert_instance_of Berylx::Ok, result
    assert_equal 'new', store.get('a').body
    assert_equal 'overwritten', store.get('b').body
  end

  # A new key is compensated by deleting it; a rewritten one by restoring the
  # bytes that were there. The inverse is read before the write, not guessed
  # afterwards.
  def test_a_failing_scope_compensates_new_and_overwritten_keys_differently
    store = seeded
    result = Berylx::Root[].call(write_two(fail_after: true), handlers: Sodalite::Store.handlers(store))

    assert_instance_of Berylx::Err, result
    assert_nil store.get('a')
    assert_equal 'original', store.get('b').body
  end

  def test_compensation_runs_backwards
    order = []
    store = Sodalite::Store.memory
    watcher = Class.new(SimpleDelegator) do
      define_method(:delete) do |key|
        order << key
        __getobj__.delete(key)
      end
    end.new(store)

    workflow = Sodalite::Store.saga(
      :write,
      Berylx::Task[:a] { |lay, io| io.perform(Sodalite::Store::PUT, %w[one x]) && lay } >>
        Berylx::Task[:b] { |lay, io| io.perform(Sodalite::Store::PUT, %w[two y]) && lay } >>
        Berylx::Task[:c] { |lay| lay.reject(:conflict, 'no') }
    )
    Berylx::Root[].call(workflow, handlers: Sodalite::Store.handlers(watcher))

    assert_equal %w[two one], order
  end

  # The honest limit, stated as a test rather than a footnote: compensation
  # cannot unread. Anyone who read between the write and the failure saw the
  # value that the compensation later removed.
  def test_compensation_cannot_undo_a_read_that_already_happened
    store = Sodalite::Store.memory
    seen = []
    workflow = Sodalite::Store.saga(
      :write,
      Berylx::Task[:put] { |lay, io| io.perform(Sodalite::Store::PUT, %w[k v]) && lay } >>
        Berylx::Task[:read] { |lay, io| seen << io.perform(Sodalite::Store::GET, 'k').body and lay } >>
        Berylx::Task[:fail] { |lay| lay.reject(:conflict, 'no') }
    )
    Berylx::Root[].call(workflow, handlers: Sodalite::Store.handlers(store))

    assert_nil store.get('k')
    assert_equal ['v'], seen
  end
end
