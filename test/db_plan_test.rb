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
      [step(:add_attribute, :posts, :author, Sodalite::DB.fk(:users), 1), { posts: { id: :integer } },
       %i[posts users], [:'posts.author'], []],
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
      # The presentation holds an object the step does not name, which is what
      # makes this row say anything: a decomposition claims the fibres it makes
      # and not `users`, which some other step made and still supplies.
      [step(:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }),
       { users: users, animals: animals }, [:'animals.species'],
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

  # A foreign key is a morphism, so the column that carries it needs its codomain
  # to be an object already. The solver reads that off `requires`: `users` only
  # comes into existence in the second layer, so the column pointing at it waits
  # for the third however the four were declared.
  def test_an_added_foreign_key_waits_for_the_table_it_points_at
    accounts = [:create_table, :accounts, { id: :integer }]
    rename = %i[rename_table accounts users]
    posts = [:create_table, :posts, { id: :integer }]
    author = [:add_attribute, :posts, :author, Sodalite::DB.fk(:users), 1]

    [[accounts, rename, posts, author], [posts, author, accounts, rename]].each do |declared|
      plan = Sodalite::DB.history(*declared).plan

      assert_equal %i[posts users], plan.order.last.requires({})
      assert_equal 3, plan.layers.size
      assert_equal [:rename_table], plan.layers[1].map(&:kind)
      assert_equal [:add_attribute], plan.layers[2].map(&:kind)
    end
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
