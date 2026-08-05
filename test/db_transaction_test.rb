# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# `DB.atomically` is offered as a combinator, so being composed — and therefore
# nested — is its premise, not an exotic case. This is the check that all three
# models mean the same thing by a nested scope: it joins the outermost one, gets
# no savepoint of its own, and rollback happens exactly once, at the outermost
# scope, if that scope's result is an `Err`.
#
# The conformance suite asks whether the models agree about *reading*. This asks
# whether they agree about *scope*, which is the other half of being models of
# one theory rather than three databases that happen to answer alike.
class DBNestedScopeTest < Minitest::Test
  DRIVERS = begin
    require 'sqlite3'
    require 'sequel'
    true
  rescue LoadError
    false
  end

  SCHEMA = Sodalite::DB.schema(notes: { id: :integer, body: :string })

  OUTER = { id: 1, body: 'outer' }.freeze
  INNER = { id: 2, body: 'inner' }.freeze
  LATER = { id: 3, body: 'later' }.freeze

  def setup
    @memory = Sodalite::DB.memory(SCHEMA)
  end

  # Nesting through the combinator, not by calling the model twice by hand: the
  # defect was reachable from ordinary workflow composition.
  def test_a_nested_scope_commits_every_write
    models.each do |model|
      result = run_nested(model, Berylx::Task[:done] { |lay| lay })

      assert_instance_of Berylx::Ok, result, model.class.name
      assert_equal %w[inner outer], bodies(model), model.class.name
    end
  end

  def test_a_nested_scope_rolls_back_every_write_when_the_outermost_result_is_err
    models.each do |model|
      result = run_nested(model, Berylx::Task[:fail] { |lay| lay.reject(:conflict, 'no') })

      assert_instance_of Berylx::Err, result, model.class.name
      assert_empty bodies(model), model.class.name
    end
  end

  # Whatever a raise means to a given model — `Sql` rolls back, `Memory` keeps
  # what the block already wrote — it must leave no scope open behind it, or
  # every later write in the process sits inside a transaction nobody will end.
  def test_a_nested_scope_that_raises_unwinds_to_no_scope_at_all
    models.each do |model|
      assert_raises(RuntimeError, model.class.name) do
        model.atomically do
          model.insert(:notes, OUTER)
          model.atomically { raise 'inner' }
        end
      end

      model.atomically { model.insert(:notes, LATER) }

      assert_includes bodies(model), 'later', model.class.name
    end
  end

  # The cost of letting the outermost scope decide, written down as a test
  # rather than only as a comment: an inner `Err` a combinator recovers from is
  # committed, and it is committed identically by all three models.
  def test_recovering_from_an_inner_err_commits_it
    models.each do |model|
      result = model.atomically do
        model.insert(:notes, OUTER)
        inner = model.atomically do
          model.insert(:notes, INNER)
          rejection
        end

        inner.is_a?(Berylx::Err) ? :recovered : inner
      end

      assert_equal :recovered, result, model.class.name
      assert_equal %w[inner outer], bodies(model), model.class.name
    end
  end

  # `Ledger#migrate!` claims the lock and then writes, so a migration run from
  # inside a scope took the same lock twice. A `Mutex` answers that with
  # `ThreadError`; the lock's answers themselves are unchanged.
  def test_the_migration_lock_can_be_claimed_from_inside_a_scope
    claimed = @memory.atomically { @memory.claim_lock('token') }
    released = @memory.atomically { @memory.release_lock('token') }

    assert claimed
    assert_nil released
    assert @memory.claim_lock('other')
  end

  def test_a_claimed_lock_still_refuses_a_second_claimer_from_inside_a_scope
    @memory.claim_lock('token')
    claimed = @memory.atomically { @memory.claim_lock('other') }

    refute claimed
  end

  # What makes the plain depth ivar safe is that it is only touched with the
  # monitor held and is back at zero before the monitor is released. So a thread
  # that waited at the door gets its own outermost scope: its `Err` rolls back
  # its own write and leaves the committed ones alone.
  def test_a_thread_that_waits_for_the_monitor_gets_its_own_outermost_scope
    gate = Queue.new
    awake = Queue.new
    waiting = Thread.new do
      gate.pop
      awake << :running
      @memory.atomically do
        @memory.insert(:notes, LATER)
        rejection
      end
    end

    @memory.atomically do
      @memory.insert(:notes, OUTER)
      @memory.atomically { @memory.insert(:notes, INNER) }
      gate << :go
      awake.pop
      wait_for { waiting.status == 'sleep' }
      :committed
    end

    assert_instance_of Berylx::Err, waiting.value
    assert_equal %w[inner outer], bodies(@memory)
  end

  private

  def models
    skip 'sqlite3 unavailable' unless DRIVERS

    [@memory,
     Sodalite::DB.sql(SCHEMA, Adapter.new).create_tables!,
     Sodalite::DB.sequel(SCHEMA, Sequel.sqlite).create_tables!]
  end

  def run_nested(model, finish)
    inner = Sodalite::DB.atomically(:inner, writing(:inner_row, INNER) >> finish)
    workflow = Sodalite::DB.atomically(:outer, writing(:outer_row, OUTER) >> inner)
    Berylx::Root[].call(workflow, handlers: Sodalite::DB.handlers(model))
  end

  def writing(name, row)
    Berylx::Task[name] { |_lay, io| io.perform(Sodalite::DB::INSERT, [:notes, row]) }
  end

  def rejection
    Berylx::Focus[{}].reject(:conflict, 'no')
  end

  def bodies(model)
    model.select(SCHEMA[:notes]).rows.map { |row| row[:body] }.sort
  end

  def wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # The same one-method port the conformance suite uses, kept here so the two
  # files do not reach into each other.
  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end
end
