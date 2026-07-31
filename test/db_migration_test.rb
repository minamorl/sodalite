# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  MIGRATION_SQLITE = true
rescue LoadError
  MIGRATION_SQLITE = false
end

# A schema change is a functor between presentations, and the data migration is
# what it induces on instances. Both directions are derived, so reversibility is
# computed rather than promised.
class DBHistoryTest < Minitest::Test
  HISTORY = Sodalite::DB.history(
    [:create_table, :users, { id: :integer, name: :string }],
    [:add_attribute, :users, :city, :string, 'unknown'],
    %i[rename_attribute users city town],
    [:create_table, :posts, { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }]
  )

  def test_the_composite_is_the_schema_so_nothing_is_declared_twice
    assert_equal %i[users posts], HISTORY.schema.names
    assert_equal %i[id name town], HISTORY.schema.table(:users).fields
    assert_equal %i[id title author], HISTORY.schema.table(:posts).fields
  end

  def test_a_version_is_how_far_along_the_composite_a_database_got
    assert_equal %i[id name], HISTORY.schema_at(1).table(:users).fields
    assert_equal %i[id name city], HISTORY.schema_at(2).table(:users).fields
  end

  # Losing information is exactly what a non-injective map does, so the question
  # is answerable before a single statement runs.
  def test_reversibility_is_computed_from_the_steps_not_promised
    assert HISTORY.reversible_to?(0)
    assert_empty HISTORY.irreversible_steps

    forgetful = Sodalite::DB.history(*HISTORY.steps, %i[drop_attribute users name])

    refute forgetful.reversible_to?(0)
    assert_equal ['drop_attribute(:users, :name)'], forgetful.irreversible_steps.map(&:to_s)
    assert forgetful.reversible_to?(5)
  end

  def test_a_forgetful_step_has_no_inverse_and_says_so
    drop = Sodalite::DB::Step[:drop_table, :users]

    error = assert_raises(Sodalite::DB::MigrationError) { drop.inverse(HISTORY.spec_at(1)) }

    assert_match(/forgets information and has no inverse/, error.message)
  end

  # A rename is an isomorphism, so applying it and then its inverse is the
  # identity on the presentation.
  def test_a_rename_composed_with_its_inverse_is_the_identity
    before = HISTORY.spec_at(2)
    rename = Sodalite::DB::Step[:rename_attribute, :users, :city, :town]
    after = rename.apply(before)

    assert_equal before, rename.inverse(before).apply(after)
  end

  def test_a_composite_that_does_not_typecheck_fails_at_declaration
    assert_raises(KeyError) do
      Sodalite::DB.history([:add_attribute, :ghosts, :name, :string, ''])
    end
  end

  def test_an_unknown_step_kind_is_refused
    assert_raises(Sodalite::DB::MigrationError) { Sodalite::DB.history(%i[reticulate users]) }
  end
end

# Both models carry the same history, and the conformance discipline extends to
# "migrate, then query".
class DBMigrationConformanceTest < Minitest::Test
  HISTORY = DBHistoryTest::HISTORY

  def setup
    skip 'sqlite3 unavailable' unless MIGRATION_SQLITE

    @memory = Sodalite::DB.memory(Sodalite::DB::Schema.new(HISTORY.spec_at(1)))
    @sql = Sodalite::DB.sql(Sodalite::DB::Schema.new(HISTORY.spec_at(0)), Adapter.new)
    @sql.migrate!(Sodalite::DB.history(*HISTORY.steps.first(1)))
    [@memory, @sql].each { |model| model.insert(:users, { id: 1, name: 'mina' }) }
  end

  # `ALTER TABLE ADD COLUMN` leaves existing rows NULL, while the induced map on
  # instances says the column is the constant default. Without the backfill the
  # two models disagree — which is how this was found.
  def test_both_models_carry_existing_rows_through_the_same_migration
    [@memory, @sql].each { |model| model.migrate!(HISTORY) }

    assert_equal @memory.select(HISTORY.schema[:users]), @sql.select(HISTORY.schema[:users])
    assert_equal 'unknown', @memory.select(HISTORY.schema[:users]).rows.first[:town]
  end

  def test_queries_agree_after_migrating
    [@memory, @sql].each do |model|
      model.migrate!(HISTORY)
      model.insert(:posts, { id: 10, title: 'hi', author: 1 })
    end

    query = HISTORY.schema[:posts].follow(:author).group(:town).count(:people)

    assert_equal @memory.select(query), @sql.select(query)
  end

  def test_migrating_twice_applies_nothing_the_second_time
    2.times { [@memory, @sql].each { |model| model.migrate!(HISTORY) } }

    assert_equal [0, 1, 2, 3], @sql.applied.keys.sort
    assert_equal 1, @memory.rows(:users).size
  end

  # The ledger records each step's fingerprint, so a migration edited after it
  # ran is caught rather than silently meaning something else.
  def test_a_migration_edited_after_it_ran_is_caught
    @sql.migrate!(HISTORY)
    edited = Sodalite::DB.history(
      [:create_table, :users, { id: :integer, name: :string }],
      [:add_attribute, :users, :city, :string, 'somewhere else']
    )

    error = assert_raises(Sodalite::DB::MigrationError) { @sql.migrate!(edited) }

    assert_match(/was applied as/, error.message)
  end

  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end
end
