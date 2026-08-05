# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# A step *is* its content, so its address has to be a function of that content
# and of nothing else. The ledger is keyed by the address, so anything else
# leaking in — the order a Hash literal was typed in, the rendering `inspect`
# happens to choose — turns a refactor into an unapplied migration and makes
# `verify!` refuse to boot.
class DBStepIdentityTest < Minitest::Test
  def step(kind, *)
    Sodalite::DB::Step[kind, *]
  end

  # A Hash is an unordered map. Permuting the fields of a `create_table` changes
  # no presentation, so it must not change the address either.
  def test_a_field_hash_is_content_and_its_insertion_order_is_not
    assert_equal step(:create_table, :users, { id: :integer, name: :string }).fingerprint,
                 step(:create_table, :users, { name: :string, id: :integer }).fingerprint
  end

  # The rendering is recursive, so a Hash nested inside the argument list is
  # normalised on the same terms as one at the top.
  def test_a_nested_hash_is_normalised_at_every_depth
    assert_equal step(:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }).fingerprint,
                 step(:split_table, :animals, :species, { 'dogs' => :dogs, 'cats' => :cats }).fingerprint
  end

  # A morphism is not the name of its codomain: `fk(:users)` says `posts -> users`
  # and `:users` says the column holds a value of type `users`. Two declarations,
  # two addresses — and the FK's own field order is still not content.
  def test_a_foreign_key_renders_as_a_morphism_rather_than_as_its_target
    morphism = step(:create_table, :posts, { id: :integer, author: Sodalite::DB.fk(:users) })
    leaf = step(:create_table, :posts, { id: :integer, author: :users })

    refute_equal morphism.fingerprint, leaf.fingerprint
    assert_equal morphism.fingerprint,
                 step(:create_table, :posts, { author: Sodalite::DB.fk(:users), id: :integer }).fingerprint
  end

  # Every atom names its kind and its length, so distinct values stay distinct
  # once they are concatenated into one string.
  def test_a_symbol_a_string_and_an_integer_are_three_different_defaults
    defaults = [:'1', '1', 1, 1.0, nil, true, false]
    addresses = defaults.map { |value| step(:add_attribute, :users, :city, :string, value).fingerprint }

    assert_equal defaults.size, addresses.uniq.size
  end

  # An Array is ordered data: which table is the first injection of the coproduct
  # is part of what the step says, so sorting it would erase meaning.
  def test_an_arrays_order_still_distinguishes_two_steps
    refute_equal step(:merge_tables, %i[cats dogs], :animals, :species).fingerprint,
                 step(:merge_tables, %i[dogs cats], :animals, :species).fingerprint
  end

  # Falling back to `inspect` for an unanticipated value would put insertion
  # order back into the address somewhere nobody is looking.
  def test_a_value_the_normaliser_does_not_know_is_refused_rather_than_inspected
    error = assert_raises(Sodalite::DB::MigrationError) do
      step(:add_attribute, :users, :seen_at, :string, Object.new).fingerprint
    end

    assert_match(/has no fingerprint rendering/, error.message)
  end

  # A foreign key column needs its codomain to exist, exactly as `create_table`
  # does, so the arrow cannot be ordered before the object it points at.
  def test_adding_a_foreign_key_column_requires_the_table_it_points_at
    assert_equal %i[posts users], step(:add_attribute, :posts, :author, Sodalite::DB.fk(:users), 1).requires({})
    assert_equal [:posts], step(:add_attribute, :posts, :title, :string, '').requires({})

    order = Sodalite::DB.history(
      [:add_attribute, :posts, :author, Sodalite::DB.fk(:users), 1],
      [:create_table, :posts, { id: :integer }],
      [:create_table, :users, { id: :integer }]
    ).plan.order

    assert_equal :add_attribute, order.last.kind
  end

  # `Plan` exists because declaration order carries no meaning, so a declaration
  # order that does not typecheck is not itself a defect. The composite is folded
  # — and validated at construction — along the solved order.
  def test_a_history_is_folded_along_the_solved_order_not_the_declared_one
    history = Sodalite::DB.history(
      [:add_attribute, :users, :city, :string, 'unknown'],
      [:create_table, :users, { id: :integer }]
    )

    assert_equal %i[create_table add_attribute], history.plan.order.map(&:kind)
    assert_equal({ users: { id: :integer } }, history.spec_after(1))
    assert_equal %i[id city], history.schema_after(2).table(:users).fields
    assert_equal history.schema.names, history.schema_after(history.size).names
  end

  # `count` is a position on the same number line `rollback!(to:)` indexes, so
  # the answer has to be read off `plan.order` and not off the declaration.
  def test_reversibility_counts_along_the_solved_order_too
    history = Sodalite::DB.history(
      %i[drop_attribute users city],
      [:create_table, :users, { id: :integer, city: :string }]
    )

    assert_equal %i[create_table drop_attribute], history.plan.order.map(&:kind)
    refute history.reversible_after?(1)
    assert history.reversible_after?(2)
    assert_equal [:drop_attribute], history.irreversible_steps.map(&:kind)
  end
end
