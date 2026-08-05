# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# Migration order is solved from presentations rather than promised by the
# declaration, so branches can merge without re-meaning stored positions.
class DBPlanTest < Minitest::Test
  def step(kind, *)
    Sodalite::DB::Step[kind, *]
  end

  def test_every_step_states_what_it_requires_provides_and_removes
    users = { id: :integer, city: :string }
    animals = { id: :integer, name: :string, species: :string }
    cases = [
      [step(:create_table, :posts, { id: :integer, author: Sodalite::DB.fk(:users) }), {},
       [:users], %i[posts posts.id posts.author], []],
      [step(:add_attribute, :users, :city, :string, ''), { users: { id: :integer } },
       [:users], [:'users.city'], []],
      [step(:drop_attribute, :users, :city), { users: users },
       [:'users.city'], [], [:'users.city']],
      [step(:rename_attribute, :users, :city, :town), { users: users },
       [:'users.city'], [:'users.town'], [:'users.city']],
      [step(:rename_table, :users, :people), { users: users },
       [:users], %i[people people.id people.city], %i[users users.*]],
      [step(:drop_table, :users), { users: users },
       [:users], [], %i[users users.*]],
      [step(:merge_tables, %i[cats dogs], :animals, :species),
       { cats: { id: :integer, name: :string }, dogs: { id: :integer, name: :string } },
       %i[cats dogs], %i[animals animals.*], %i[cats cats.* dogs dogs.*]],
      [step(:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }),
       { animals: animals }, [:'animals.species'],
       %i[cats cats.id cats.name dogs dogs.id dogs.name], %i[animals animals.*]]
    ]

    cases.each do |migration, spec, required, provided, removed|
      assert_equal required, migration.requires(spec)
      assert_equal provided, migration.provides(spec)
      assert_equal removed, migration.removes(spec)
    end
  end

  # Isomorphism preserves information, but a rename does not include the old
  # presentation and therefore is unsafe for code still using the old name.
  def test_expansion_and_reversibility_are_different_properties
    rename = step(:rename_attribute, :users, :city, :town)

    assert_predicate rename, :reversible?
    refute_predicate rename, :expand?
    assert_predicate step(:create_table, :users, { id: :integer }), :expand?
    refute_predicate step(:drop_table, :users), :expand?
  end

  def test_declaration_order_does_not_choose_the_layers
    users = [:create_table, :users, { id: :integer }]
    posts = [:create_table, :posts, { id: :integer }]
    add_city = [:add_attribute, :users, :city, :string, 'unknown']
    left = Sodalite::DB.history(users, posts, add_city)
    right = Sodalite::DB.history(posts, users, add_city)

    assert_equal(left.plan.layers.map { |layer| layer.map(&:fingerprint) },
                 right.plan.layers.map { |layer| layer.map(&:fingerprint) })
  end

  def test_an_attribute_may_be_declared_before_the_table_that_supplies_it
    history = Sodalite::DB.history(
      [:add_attribute, :users, :city, :string, 'x'],
      [:create_table, :users, { id: :integer, name: :string }]
    )

    assert_equal(%i[create_table add_attribute],
                 history.plan.layers.map { |layer| layer.fetch(0).kind })
    assert_equal %i[id name city], history.schema.table(:users).fields
  end

  def test_the_same_step_set_has_one_plan_and_schema_in_every_declaration_order
    steps = [
      [:create_table, :users, { id: :integer, name: :string }],
      [:add_attribute, :users, :city, :string, 'x'],
      [:create_table, :posts, { id: :integer, author: Sodalite::DB.fk(:users) }]
    ]
    histories = steps.permutation.map { |declaration| Sodalite::DB.history(*declaration) }

    assert(histories.map { |history| history.plan.layers }
                    .all? { |layers| layers == histories.first.plan.layers })
    expected = histories.first.spec_at(histories.first.size)

    assert(histories.all? { |history| history.spec_at(history.size) == expected })
  end

  def test_independent_steps_share_a_layer_and_fingerprints_choose_the_order
    history = Sodalite::DB.history(
      [:create_table, :users, { id: :integer }],
      [:create_table, :posts, { id: :integer }]
    )

    assert_equal 1, history.plan.layers.size
    assert_equal 2, history.plan.width
    assert_equal history.steps.map(&:fingerprint).sort, history.plan.order.map(&:fingerprint)
    assert_predicate history.plan, :expand_only?
    assert_empty history.plan.contract_steps
  end

  def test_two_steps_cannot_supply_the_same_name
    error = assert_raises(Sodalite::DB::MigrationError) do
      Sodalite::DB.history(
        [:create_table, :users, { id: :integer }],
        [:create_table, :users, { id: :string }]
      )
    end

    assert_match(/create_table\(:users/, error.message)
  end

  def test_an_unprovided_requirement_fails_with_the_step
    error = assert_raises(Sodalite::DB::MigrationError) do
      Sodalite::DB.history([:add_attribute, :ghosts, :name, :string, ''])
    end

    assert_match(/add_attribute\(:ghosts/, error.message)
  end

  def test_a_cycle_lists_every_unplaced_step
    error = assert_raises(Sodalite::DB::MigrationError) do
      Sodalite::DB.history(
        [:create_table, :cats, { id: :integer, friend: Sodalite::DB.fk(:dogs) }],
        [:create_table, :dogs, { id: :integer, friend: Sodalite::DB.fk(:cats) }]
      )
    end

    assert_match(/create_table\(:cats/, error.message)
    assert_match(/create_table\(:dogs/, error.message)
  end

  # A removal separates two supplies of one name, so this is replacement rather
  # than the contradictory assertion that the name is born twice.
  def test_a_removed_attribute_can_be_supplied_again
    history = Sodalite::DB.history(
      [:create_table, :users, { id: :integer, city: :string }],
      %i[drop_attribute users city],
      [:add_attribute, :users, :city, :string, 'unknown']
    )

    assert_equal 3, history.plan.layers.size
  end
end
