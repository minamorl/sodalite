# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  SPLIT_SQLITE = true
rescue LoadError
  SPLIT_SQLITE = false
end

# A decomposition used to be a step no `History` could hold. `Step#provides`
# answered with the whole resulting presentation, so a split claimed every object
# in the database — the ones other steps make included — and `Plan` read one name
# as supplied twice and refused to schedule it. Everything the migration runner
# had learned to do with a split, it did in a history nobody could construct.
#
# So what is checked here is planability: a split claims the fibres its `into` map
# names and nothing else, which is what lets a history hold one beside anything
# else — and solve to one order however it was typed.
class DBSplitPlanabilityTest < Minitest::Test
  USERS = [:create_table, :users, { id: :integer, name: :string }].freeze
  ANIMALS = [:create_table, :animals,
             { id: :integer, name: :string, owner: Sodalite::DB.fk(:users), species: :string }].freeze
  SPLIT = [:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }].freeze

  # The fibres and their attributes. `users` is in the presentation and is not a
  # fibre, so claiming it was the whole defect: the step that made it supplies it
  # already, and one name cannot be born twice.
  def test_a_decomposition_claims_its_fibres_and_not_the_objects_beside_them
    step = Sodalite::DB::Step[*SPLIT]
    spec = { users: { id: :integer, name: :string },
             animals: { id: :integer, name: :string, species: :string } }

    assert_equal %i[cats cats.id cats.name dogs dogs.id dogs.name], step.provides(spec)
  end

  # The tag column goes with the fibres it named, so it is neither a field of one
  # nor a name the step leaves behind.
  def test_the_tag_is_removed_with_the_object_it_discriminated
    step = Sodalite::DB::Step[*SPLIT]
    spec = { animals: { id: :integer, name: :string, species: :string } }

    assert_equal %i[animals animals.*], step.removes(spec)
    refute_includes step.provides(spec), :'cats.species'
  end

  def test_a_history_holding_a_split_beside_another_object_solves
    history = Sodalite::DB.history(USERS, ANIMALS, SPLIT)

    assert_equal([[:create_table], [:create_table], [:split_table]],
                 history.plan.layers.map { |layer| layer.map(&:kind) })
    assert_equal %i[users cats dogs], history.schema.names
    assert_equal %i[id name owner], history.schema.table(:cats).fields
  end

  # The solver reads presentations, not the order someone typed. `users` and
  # `animals` are independent so either may come first, and the split may be typed
  # anywhere after the object it decomposes — `History` folds the presentations in
  # declaration order, and that fold is what tells a split what its fibres hold.
  def test_declaration_order_does_not_choose_the_order_a_split_is_carried_in
    declarations = [[USERS, ANIMALS, SPLIT], [ANIMALS, USERS, SPLIT], [ANIMALS, SPLIT, USERS]]
    solved = declarations.map { |declared| Sodalite::DB.history(*declared).fingerprints }

    assert_equal 1, solved.uniq.size
    assert_equal Sodalite::DB.history(USERS, ANIMALS, SPLIT).plan.order.map(&:fingerprint), solved.first
  end

  # Σ_F and the decomposition of another coproduct in one history, with an object
  # beside them that neither names. The coproduct's sources are independent of the
  # split's source, so they share layers rather than queueing behind it.
  def test_a_coproduct_and_a_decomposition_solve_in_one_history
    history = Sodalite::DB.history(
      USERS, ANIMALS, SPLIT,
      [:create_table, :hens, { id: :integer, name: :string }],
      [:create_table, :ducks, { id: :integer, name: :string }],
      [:merge_tables, %i[hens ducks], :birds, :kind]
    )

    assert_equal([%i[create_table create_table create_table], %i[create_table merge_tables], [:split_table]],
                 history.plan.layers.map { |layer| layer.map(&:kind).sort })
    assert_equal %i[users birds cats dogs], history.schema.names
  end

  # A fibre is an object like any other: a morphism can point at it and its
  # attributes can be renamed. Both steps read the fibre's names off the split's
  # `provides`, so both wait for the layer after it.
  def test_a_step_that_consumes_a_fibre_waits_for_the_decomposition
    history = Sodalite::DB.history(USERS, ANIMALS, SPLIT,
                                   [:create_table, :toys, { id: :integer, owner: Sodalite::DB.fk(:cats) }],
                                   %i[rename_attribute cats name handle])

    assert_equal([[:create_table], [:create_table], [:split_table], %i[create_table rename_attribute]],
                 history.plan.layers.map { |layer| layer.map(&:kind).sort })
    assert_equal %i[id handle owner], history.schema.table(:cats).fields
  end

  # The neighbour, checked with the same eye. `merge_tables` claims `into` and
  # `into.*` — the wildcard rather than the fields — and `Plan#covers?` reads a
  # wildcard as covering every name beneath it, so a later step that *requires* an
  # attribute of the coproduct resolves against it. That is what the wildcard is
  # for, and it is the half of it that works.
  def test_a_step_requiring_an_attribute_of_the_coproduct_resolves_against_the_wildcard
    history = Sodalite::DB.history(
      [:create_table, :cats, { id: :integer, name: :string }],
      [:create_table, :dogs, { id: :integer, name: :string }],
      [:merge_tables, %i[cats dogs], :animals, :species],
      %i[drop_attribute animals name]
    )

    assert_equal [:'animals.name'], history.plan.order.last.requires({})
    assert_equal([%i[create_table create_table], [:merge_tables], [:drop_attribute]],
                 history.plan.layers.map { |layer| layer.map(&:kind) })
  end
end

# A history that solves is not yet a database that arrives. These are the two
# steps this lane made plannable and carryable, run from empty against sqlite3:
# a decomposition beside an object it does not name, and a rename that has to take
# the indexes of its morphisms with it.
class DBSplitPlanabilityRunTest < Minitest::Test
  FLOCK = Sodalite::DB.history(DBSplitPlanabilityTest::USERS,
                               DBSplitPlanabilityTest::ANIMALS,
                               DBSplitPlanabilityTest::SPLIT)

  RENAMED = Sodalite::DB.history(
    [:create_table, :users, { id: :integer, name: :string }],
    [:create_table, :posts, { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }],
    %i[rename_table posts writings]
  )

  def setup
    skip 'sqlite3 unavailable' unless SPLIT_SQLITE

    @adapter = Adapter.new
  end

  # Through `migrate!`, which is the whole point: the runner checks the tag covers
  # before it carries and carries the step in one transaction, and until now it
  # could only do that for a history with nothing else in it.
  def test_a_history_holding_a_split_beside_another_object_carries_it
    model = carry(FLOCK, after: 2)
    model.insert(:users, { id: 1, name: 'mina' })
    model.insert(:animals, { id: 2, name: 'mi', owner: 1, species: 'cats' })
    model.insert(:animals, { id: 3, name: 'pochi', owner: 1, species: 'dogs' })
    model.migrate!(FLOCK)

    assert_equal [{ id: 2, name: 'mi', owner: 1 }], model.select(FLOCK.schema[:cats]).rows
    assert_equal [{ id: 3, name: 'pochi', owner: 1 }], model.select(FLOCK.schema[:dogs]).rows
    assert_equal %w[index_cats_on_owner], index_list(:cats)
    assert_equal [{ id: 1, name: 'mina' }], model.select(FLOCK.schema[:users]).rows
  end

  # Both backends keep an index across `RENAME TO` under the name it was created
  # with, so the renamed object was left holding `index_posts_on_author` — a name
  # `SQL.index_name` does not compute for it. Measured on either side of the step
  # rather than read off the statements, because what the statement says and what
  # the database then has are different facts.
  def test_a_renamed_object_takes_the_indexes_of_its_morphisms_with_it
    model = carry(RENAMED, after: 2)
    model.insert(:users, { id: 1, name: 'mina' })
    model.insert(:posts, { id: 2, title: 'hi', author: 1 })

    assert_equal %w[index_posts_on_author], index_list(:posts)

    model.migrate!(RENAMED)

    assert_equal %w[index_writings_on_author], index_list(:writings)
    assert_empty index_list(:posts)
    assert_equal [{ id: 2, title: 'hi', author: 1 }], model.select(RENAMED.schema[:writings]).rows
  end

  # What the leftover name cost: an index nothing could find again is also a name
  # nothing else can take, and `CREATE INDEX` has no `IF NOT EXISTS`. So a later
  # object called `posts` raised on an index it never emitted — measured here by
  # making one.
  def test_the_name_a_rename_freed_can_be_taken_by_a_later_object
    carry(RENAMED, after: 3)
    fresh = { id: :integer, body: :string, author: Sodalite::DB.fk(:users) }
    step = Sodalite::DB::Step[:create_table, :posts, fresh]
    schema = Sodalite::DB::Schema.new(RENAMED.spec_after(3).merge(posts: fresh))
    Sodalite::DB::DDL.ddl(step, schema).each { |sql, binds| @adapter.execute(sql, binds) }

    assert_equal %w[index_posts_on_author], index_list(:posts)
    assert_equal %w[index_writings_on_author], index_list(:writings)
  end

  # The prefix is carried first so rows can go in under the old presentation,
  # which is the only way the rest of the history has anything to carry.
  def carry(history, after:)
    prefix = Sodalite::DB.history(*history.plan.order.first(after))
    Sodalite::DB.sql(Sodalite::DB::Schema.new({}), @adapter).migrate!(prefix)
  end

  # Named rather than bound: a `PRAGMA` takes an identifier, so it is quoted the
  # way every other identifier this suite writes is.
  def index_list(table)
    @adapter.execute("PRAGMA index_list(#{Sodalite::DB::SQL.quote(table)})", []).map { |row| row[1] }.sort
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
