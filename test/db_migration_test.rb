# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
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

  # Σ_F: the coproduct of two objects with the same shape, tagged by which
  # injection each element came through. Its inverse decomposes it along the tag,
  # so both directions are reversible.
  ANIMALS = Sodalite::DB.history(
    [:create_table, :cats, { id: :integer, name: :string }],
    [:create_table, :dogs, { id: :integer, name: :string }],
    [:merge_tables, %i[cats dogs], :animals, :species]
  )

  def test_the_coproduct_tags_each_element_with_its_injection
    assert_equal [:animals], ANIMALS.schema.names
    assert_equal %i[id name species], ANIMALS.schema.table(:animals).fields
  end

  def test_a_coproduct_of_objects_with_different_shapes_is_not_a_table
    error = assert_raises(Sodalite::DB::MigrationError) do
      Sodalite::DB.history(
        [:create_table, :cats, { id: :integer, name: :string }],
        [:create_table, :dogs, { id: :integer, breed: :string }],
        [:merge_tables, %i[cats dogs], :animals, :species]
      )
    end

    assert_match(/do not share a shape/, error.message)
  end

  def test_the_coproduct_and_its_decomposition_are_inverse
    before = ANIMALS.spec_at(2)
    merge = ANIMALS.steps.last

    assert_predicate merge, :reversible?
    assert_equal before, merge.inverse(before).apply(merge.apply(before))
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

    first_step = Sodalite::DB.history(*HISTORY.steps.first(1))
    @memory = Sodalite::DB.memory(Sodalite::DB::Schema.new(HISTORY.spec_at(1)))
    @sql = Sodalite::DB.sql(Sodalite::DB::Schema.new(HISTORY.spec_at(0)), Adapter.new).migrate!(first_step)
    @sequel = Sodalite::DB.sequel(Sodalite::DB::Schema.new(HISTORY.spec_at(0)), Sequel.sqlite)
                          .migrate!(first_step)
    models.each { |model| model.insert(:users, { id: 1, name: 'mina' }) }
  end

  def models
    [@memory, @sql, @sequel]
  end

  # `ALTER TABLE ADD COLUMN` leaves existing rows NULL, while the induced map on
  # instances says the column is the constant default. Without the backfill the
  # two models disagree — which is how this was found.
  def test_every_model_carries_existing_rows_through_the_same_migration
    models.each { |model| model.migrate!(HISTORY) }
    expected = @memory.select(HISTORY.schema[:users])

    assert_equal expected, @sql.select(HISTORY.schema[:users])
    assert_equal expected, @sequel.select(HISTORY.schema[:users])
    assert_equal 'unknown', expected.rows.first[:town]
  end

  def test_queries_agree_after_migrating
    models.each do |model|
      model.migrate!(HISTORY)
      model.insert(:posts, { id: 10, title: 'hi', author: 1 })
    end

    query = HISTORY.schema[:posts].follow(:author).group(:town).count(:people)

    assert_equal @memory.select(query), @sql.select(query)
    assert_equal @memory.select(query), @sequel.select(query)
  end

  def test_migrating_twice_applies_nothing_the_second_time
    2.times { models.each { |model| model.migrate!(HISTORY) } }

    assert_equal [0, 1, 2, 3], @sql.applied.keys.sort
    assert_equal [0, 1, 2, 3], @sequel.applied.keys.sort
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

  # What the Sequel backend actually buys, measured rather than assumed. The
  # hand-written model interpolates identifiers bare and spells an offset the way
  # SQLite does; Sequel quotes and knows the dialect.
  def test_the_sequel_backend_quotes_identifiers_the_hand_written_one_does_not
    reserved = Sodalite::DB.schema(order: { id: :integer, select: :string })
    sequel = Sodalite::DB.sequel(reserved, Sequel.sqlite).create_tables!
    sequel.insert(:order, { id: 1, select: 'x' })

    assert_equal [{ id: 1, select: 'x' }], sequel.select(reserved[:order].where(:select, 'x')).rows
    assert_includes Sodalite::DB::SQL.compile(reserved[:order].where(:select, 'x')).first, 'FROM order t0'
  end

  def test_a_reserved_table_name_breaks_the_hand_written_backend
    reserved = Sodalite::DB.schema(order: { id: :integer, select: :string })
    sql = Sodalite::DB.sql(reserved, Adapter.new)

    assert_raises(SQLite3::SQLException) { sql.create_tables! }
  end

  # Every model carries the coproduct the same way: one disjoint union of
  # Hashes, one INSERT ... SELECT per injection, one dataset insert per row.
  def test_every_model_carries_the_coproduct_identically
    history = DBHistoryTest::ANIMALS
    first_two = Sodalite::DB.history(*history.steps.first(2))
    memory = Sodalite::DB.memory(Sodalite::DB::Schema.new(history.spec_at(2)))
    sql = Sodalite::DB.sql(Sodalite::DB::Schema.new(history.spec_at(0)), Adapter.new).migrate!(first_two)
    sequel = Sodalite::DB.sequel(Sodalite::DB::Schema.new(history.spec_at(0)), Sequel.sqlite)
                         .migrate!(first_two)
    [memory, sql, sequel].each do |model|
      model.insert(:cats, { id: 1, name: 'mi' })
      model.insert(:dogs, { id: 2, name: 'pochi' })
      model.migrate!(history)
    end

    query = history.schema[:animals].order(:id)

    assert_equal memory.select(query), sql.select(query)
    assert_equal(%w[cats dogs], memory.select(query).map { |row| row[:species] })
  end

  def test_the_decomposition_puts_the_elements_back
    history = Sodalite::DB.history(
      *DBHistoryTest::ANIMALS.steps,
      [:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }]
    )
    memory = Sodalite::DB.memory(Sodalite::DB::Schema.new(history.spec_at(2)))
    memory.insert(:cats, { id: 1, name: 'mi' })
    memory.insert(:dogs, { id: 2, name: 'pochi' })
    memory.migrate!(history)

    assert_equal [{ id: 1, name: 'mi' }], memory.rows(:cats)
    assert_equal [{ id: 2, name: 'pochi' }], memory.rows(:dogs)
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
