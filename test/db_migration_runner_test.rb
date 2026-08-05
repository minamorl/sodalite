# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'
require 'socket'

begin
  require 'sqlite3'
  require 'sequel'
  RUNNER_SQLITE = true
rescue LoadError
  RUNNER_SQLITE = false
end

RUNNER_EMPTY = Sodalite::DB::Schema.new({})

# What an interruption looks like from inside: something raised, and the process
# never reached the next thing it was going to do.
class MigrationInterrupted < StandardError; end

# The one-method port, with a fault in it. `nth` is a statement *count* rather
# than a pattern because that is what an interruption is: the process stopped
# between two statements, and which two was not its choice. It fires once — the
# count keeps rising past it — so the same connection can be read afterwards to
# see what the database was left holding.
class Fragile
  attr_reader :statements

  def initialize(nth: nil)
    @db = SQLite3::Database.new(':memory:')
    @statements = []
    @nth = nth
  end

  def execute(sql, binds)
    @statements << sql
    raise MigrationInterrupted, sql if @statements.size == @nth

    @db.execute(sql, binds)
  end

  def tables
    execute("SELECT name FROM sqlite_master WHERE type = 'table'", []).flatten.map(&:to_sym)
  end

  def columns(table)
    execute("PRAGMA table_info(#{table})", []).map { |row| row[1] }
  end
end

# A step is one transaction, in every model.
#
# `carry` runs a list of statements and `record_step` writes the row that says
# it ran. Interrupted between them the database is changed and the ledger is
# silent, so the next run carries the step again — `ADD COLUMN` against a column
# that is already there — and from that point the only way forward is editing
# the ledger by hand. These are the tests that say the gap is closed, and the
# rerun is the half that proves it was worth closing.
class DBMigrationScopeTest < Minitest::Test
  HISTORY = Sodalite::DB.history([:create_table, :users, { id: :integer, name: :string }])

  # `add_attribute` is the step that compiles to more than one statement —
  # `ADD COLUMN` and the backfill — which is where an interruption lands
  # *inside* a step rather than between two.
  BACKFILL = Sodalite::DB.history(
    [:create_table, :users, { id: :integer, name: :string }],
    [:add_attribute, :users, :city, :string, 'unknown']
  )

  # The model, and a way to ask what the storage actually holds. That is not the
  # same question as what `schema` says, and after a step that did not hold it is
  # the only one worth asking.
  Runner = Struct.new(:model, :tables)

  def runners
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    adapter = Fragile.new
    db = Sequel.sqlite
    memory = Sodalite::DB.memory(RUNNER_EMPTY)
    [Runner.new(memory, -> { memory.instance_variable_get(:@store).keys }),
     Runner.new(Sodalite::DB.sql(RUNNER_EMPTY, adapter), -> { adapter.tables }),
     Runner.new(Sodalite::DB.sequel(RUNNER_EMPTY, db), -> { db.tables })]
  end

  # Stop the first step this model carries, once, after `carry` and before
  # `record_step` — the exact gap the scope exists to close.
  def interrupt_once(model)
    armed = [true]
    model.define_singleton_method(:carry) do |step|
      super(step)
      raise MigrationInterrupted, step.to_s if armed.pop
    end
    model
  end

  def test_a_step_that_raises_leaves_neither_the_schema_change_nor_the_ledger_row
    runners.each do |runner|
      interrupt_once(runner.model)

      assert_raises(MigrationInterrupted, runner.model.class.name) { runner.model.migrate!(HISTORY) }
      assert_empty runner.model.applied, runner.model.class.name
      refute_includes runner.tables.call, :users, runner.model.class.name
    end
  end

  # The point of rolling both halves back together: the next run finds the
  # database exactly as the failed one found it, so it simply applies the step.
  # Before the scope this is where `ADD COLUMN` met a column that already
  # existed and the operator met the ledger.
  def test_a_rerun_after_an_interrupted_step_applies_it
    runners.each do |runner|
      interrupt_once(runner.model)
      assert_raises(MigrationInterrupted) { runner.model.migrate!(HISTORY) }

      runner.model.migrate!(HISTORY)

      assert_equal HISTORY.fingerprints, runner.model.applied.keys, runner.model.class.name
      assert_includes runner.tables.call, :users, runner.model.class.name
    end
  end

  # A model left describing a shape its storage does not have is the same lie
  # the ledger row prevents, told in memory instead of on disk.
  def test_an_interrupted_step_leaves_the_presentation_where_it_was
    runners.each do |runner|
      interrupt_once(runner.model)
      assert_raises(MigrationInterrupted) { runner.model.migrate!(HISTORY) }

      assert_empty runner.model.schema.names, runner.model.class.name
    end
  end

  # The interruption inside a step, driven by the port rather than by overriding
  # anything: the connection stops answering at the backfill, one statement
  # after the column was added.
  def test_a_step_interrupted_between_its_own_statements_leaves_nothing_behind
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    rehearsal = Fragile.new
    Sodalite::DB.sql(RUNNER_EMPTY, rehearsal).migrate!(BACKFILL)
    broken = Fragile.new(nth: rehearsal.statements.index { |sql| sql.start_with?('UPDATE') } + 1)
    model = Sodalite::DB.sql(RUNNER_EMPTY, broken)

    assert_raises(MigrationInterrupted) { model.migrate!(BACKFILL) }
    assert_equal [BACKFILL.fingerprints.first], model.applied.keys
    refute_includes broken.columns(:users), 'city'

    model.migrate!(BACKFILL)

    assert_equal BACKFILL.fingerprints.sort, model.applied.keys.sort
    assert_includes broken.columns(:users), 'city'
  end

  def test_every_model_here_answers_that_its_ddl_is_transactional
    runners.each { |runner| assert_predicate runner.model, :transactional_ddl? }
  end

  # A model that cannot put DDL in a transaction cannot make a step atomic, so
  # it refuses rather than half-applying one. There is no override argument: a
  # refusal that can be waived is not a refusal.
  def test_a_model_without_transactional_ddl_refuses_to_migrate_or_roll_back
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    model = Sodalite::DB.sql(RUNNER_EMPTY, Fragile.new, transactional_ddl: false)

    refute_predicate model, :transactional_ddl?
    assert_match(/Sodalite::DB::Sql cannot migrate!/, refusal(model) { model.migrate!(HISTORY) })
    assert_match(/no transactional DDL/, refusal(model) { model.migrate!(HISTORY) })
    assert_match(/Sodalite::DB::Sql cannot rollback!/, refusal(model) { model.rollback!(HISTORY, to: 0) })
    assert_match(/Apply the steps by hand/, refusal(model) { model.rollback!(HISTORY, to: 0) })
    assert_empty model.applied
  end

  def refusal(_model, &)
    assert_raises(Sodalite::DB::MigrationError, &).message
  end
end

# Two steps can be asked to do something the rows do not allow, and both of them
# used to find out halfway through: a `split_table` whose tag names a table the
# decomposition never listed silently dropped those rows in the SQL models and
# raised `KeyError` in the in-memory one, and a `merge_tables` over sources that
# share a key wrote a coproduct with two rows under one key.
#
# Both are questions about rows, so both are answered by reading — inside the
# lock, before the scope, and in one wording for all three models.
class DBMigrationPreflightTest < Minitest::Test
  SPLIT = Sodalite::DB.history(
    [:create_table, :animals, { id: :integer, name: :string, species: :string }],
    [:split_table, :animals, :species, { 'cats' => :cats }]
  )

  MERGE = Sodalite::DB.history(
    [:create_table, :cats, { id: :integer, name: :string }],
    [:create_table, :dogs, { id: :integer, name: :string }],
    [:merge_tables, %i[cats dogs], :animals, :species]
  )

  def models_after(history, count)
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    prefix = Sodalite::DB.history(*history.plan.order.first(count))
    [Sodalite::DB.memory(RUNNER_EMPTY),
     Sodalite::DB.sql(RUNNER_EMPTY, Fragile.new),
     Sodalite::DB.sequel(RUNNER_EMPTY, Sequel.sqlite)].each { |model| model.migrate!(prefix) }
  end

  def rows(model, table)
    model.is_a?(Sodalite::DB::Memory) ? model.rows(table) : model.select(model.schema[table]).rows
  end

  def test_a_split_whose_tag_the_decomposition_does_not_list_is_refused_by_every_model
    messages = models_after(SPLIT, 1).map do |model|
      model.insert(:animals, { id: 1, name: 'mi', species: 'cats' })
      model.insert(:animals, { id: 2, name: 'pochi', species: 'dogs' })
      error = assert_raises(Sodalite::DB::MigrationError, model.class.name) { model.migrate!(SPLIT) }

      assert_equal 1, model.applied.size, model.class.name
      assert_equal 2, rows(model, :animals).size, model.class.name
      error.message
    end

    assert_equal ["#{SPLIT.plan.order.last} cannot be carried: animals.species = \"dogs\" is outside " \
                  'the decomposition ("cats"), so the fibres do not cover animals and the coproduct ' \
                  'cannot be taken apart along that tag'],
                 messages.uniq
  end

  def test_a_merge_whose_sources_share_a_key_is_refused_by_every_model
    messages = models_after(MERGE, 2).map do |model|
      model.insert(:cats, { id: 1, name: 'mi' })
      model.insert(:dogs, { id: 1, name: 'pochi' })
      error = assert_raises(Sodalite::DB::MigrationError, model.class.name) { model.migrate!(MERGE) }

      assert_equal 2, model.applied.size, model.class.name
      assert_equal 1, rows(model, :cats).size, model.class.name
      error.message
    end

    assert_equal ["#{MERGE.plan.order.last} cannot be carried: id 1 is in more than one of cats, dogs " \
                  '— Σ_F tags which injection an element came through but does not make the keys ' \
                  'disjoint, so two elements under one key are not two elements of the sum'],
                 messages.uniq
  end

  # The refusal is a refusal and not a rollback: nothing was carried, so there
  # is nothing to undo and the sources are still where the operator left them.
  def test_a_refused_step_writes_nothing_and_leaves_the_presentation_where_it_was
    models_after(MERGE, 2).each do |model|
      model.insert(:cats, { id: 1, name: 'mi' })
      model.insert(:dogs, { id: 1, name: 'pochi' })
      assert_raises(Sodalite::DB::MigrationError) { model.migrate!(MERGE) }

      assert_equal %i[cats dogs], model.schema.names, model.class.name
      assert_equal [{ id: 1, name: 'pochi' }], rows(model, :dogs), model.class.name
    end
  end

  # Every other step kind has nothing to check, and says so with an empty list
  # rather than with a special case at the call site.
  def test_every_other_step_kind_reports_nothing
    models_after(SPLIT, 1).each do |model|
      %i[create_table drop_table rename_table].each do |kind|
        step = kind == :rename_table ? Sodalite::DB::Step[kind, :animals, :beasts] : Sodalite::DB::Step[kind, :zoo]

        assert_empty model.send(:preflight_violations, step), "#{model.class}: #{kind}"
      end
    end
  end
end

# The lock is one row, and until this change it had no owner and no age while
# the refusal it produced speculated about a crashed runner and offered no way
# to find out. It also raced: `INSERT ... SELECT ... WHERE NOT EXISTS` is two
# runners passing the same test.
class DBMigrationLockTest < Minitest::Test
  HISTORY = Sodalite::DB.history([:create_table, :users, { id: :integer }])

  # Two runners over one database. For the in-memory model they are one object,
  # because its lock is the monitor it holds and there is no second process to
  # contend from — the answers are the same either way.
  def contenders
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    adapter = Fragile.new
    db = Sequel.sqlite
    memory = Sodalite::DB.memory(RUNNER_EMPTY)
    [[memory, memory],
     [Sodalite::DB.sql(RUNNER_EMPTY, adapter), Sodalite::DB.sql(RUNNER_EMPTY, adapter)],
     [Sodalite::DB.sequel(RUNNER_EMPTY, db), Sodalite::DB.sequel(RUNNER_EMPTY, db)]]
  end

  def models
    contenders.map(&:first)
  end

  # `assert_raises(MigrationError)` is the whole point: the loser used to reach
  # the driver's uniqueness error, which is a different class, a different
  # sentence, and no help at all.
  def test_the_loser_of_a_race_is_refused_by_name_and_told_who_holds_the_lock
    contenders.each do |winner, loser|
      assert winner.claim_lock('winner')
      error = assert_raises(Sodalite::DB::MigrationError, loser.class.name) { loser.migrate!(HISTORY) }

      assert_match(/another migration is running/, error.message)
      assert_includes error.message, "#{Socket.gethostname}:#{Process.pid}"
      assert_empty loser.applied, loser.class.name
      winner.release_lock('winner')
    end
  end

  def test_the_lock_row_carries_a_token_a_holder_and_a_time
    models.each do |model|
      assert model.claim_lock('held')

      assert_equal({ token: 'held', holder: "#{Socket.gethostname}:#{Process.pid}" },
                   model.read_lock.slice(:token, :holder), model.class.name)
      assert_equal Time.now.utc.year, Time.iso8601(model.read_lock[:acquired_at]).year, model.class.name
    end
  end

  # Explicit, never automatic. A lock that lets go of itself after a timeout is
  # not a lock, so the age is the caller's to name and a lock younger than it is
  # left alone.
  def test_steal_lock_refuses_a_young_lock_and_takes_an_old_one
    models.each do |model|
      model.claim_lock('held')
      error = assert_raises(Sodalite::DB::MigrationError, model.class.name) do
        model.steal_lock!(older_than: 3600)
      end

      assert_match(/younger than the 3600s asked for/, error.message)
      assert_equal 'held', model.read_lock[:token], model.class.name
      assert_match(/\Acleared the migration lock held by/, model.steal_lock!(older_than: 0))
      assert_nil model.read_lock, model.class.name
      assert_equal 1, model.migrate!(HISTORY).applied.size, model.class.name
    end
  end

  def test_stealing_a_lock_nobody_holds_says_so
    models.each do |model|
      assert_equal 'no migration lock is held, so there was nothing to steal',
                   model.steal_lock!(older_than: 0), model.class.name
    end
  end

  # The lock is claimed and released outside the step's transaction, so a step
  # that rolls back does not take the release with it — and the runner that
  # follows finds the lock free rather than held by a process that is gone.
  def test_a_failed_step_still_releases_the_lock
    models.each do |model|
      model.define_singleton_method(:record_step) { |step| raise MigrationInterrupted, step.to_s }
      assert_raises(MigrationInterrupted) { model.migrate!(HISTORY) }

      assert_nil model.read_lock, model.class.name
    end
  end
end

# `create_tables!` was a second road to the schema that the ledger never saw, so
# a database built by it was then refused by the thing that reads the ledger.
# The name now says which road it is.
class DBCreateTablesForTestTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(users: { id: :integer, name: :string })
  HISTORY = Sodalite::DB.history([:create_table, :users, { id: :integer, name: :string }])

  def test_a_schema_built_for_a_test_has_no_history_and_verify_refuses_it
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    [Sodalite::DB.sql(SCHEMA, Fragile.new).create_tables_for_test!,
     Sodalite::DB.sequel(SCHEMA, Sequel.sqlite).create_tables_for_test!].each do |model|
      model.insert(:users, { id: 1, name: 'mina' })
      error = assert_raises(Sodalite::DB::MigrationError, model.class.name) { model.verify!(HISTORY) }

      assert_equal [{ id: 1, name: 'mina' }], model.select(SCHEMA[:users]).rows, model.class.name
      assert_empty model.applied, model.class.name
      assert_match(/database is missing required migrations/, error.message)
    end
  end

  # The road that does leave a history is `migrate!`, and it is the one anything
  # booting against `verify!` has to take.
  def test_the_same_schema_reached_through_migrate_is_accepted
    skip 'sqlite3 unavailable' unless RUNNER_SQLITE

    [Sodalite::DB.sql(RUNNER_EMPTY, Fragile.new),
     Sodalite::DB.sequel(RUNNER_EMPTY, Sequel.sqlite)].each do |model|
      model.migrate!(HISTORY)

      assert_same model, model.verify!(HISTORY), model.class.name
    end
  end
end
