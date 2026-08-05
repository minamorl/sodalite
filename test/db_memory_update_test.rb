# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# The in-memory model is where an operation's meaning is pinned before the two
# compiling models are held to it, and an update has the most to pin: a change is
# a function of the value it replaces, it is applied to the rows a subobject
# names, and what it does to a `nothing` is a decision rather than a consequence.
#
# Its own schema, because the change vocabulary needs a nullable numeric column —
# `A + 1` where addition is defined on `A` — and the schema the conformance suite
# shares is about reading.
UPDATE_SCHEMA = Sodalite::DB.schema(
  items: { id: :integer, name: :string, stock: :integer, score: :integer?, state: :string },
  orders: { id: :integer, item: Sodalite::DB.fk(:items) }
)

UPDATE_SEED = {
  items: [
    { id: 1, name: 'lamp', stock: 1, score: 3, state: 'open' },
    { id: 2, name: 'desk', stock: 4, score: nil, state: 'open' },
    { id: 3, name: 'rug', stock: 0, score: 7, state: 'sold' }
  ],
  orders: [{ id: 10, item: 1 }]
}.freeze

class DBMemoryUpdateTest < Minitest::Test
  def setup
    @model = Sodalite::DB.memory(UPDATE_SCHEMA, UPDATE_SEED)
  end

  # Read back through `rows`, which copies out of the store. An assertion on what
  # `select` returned earlier would be an assertion about copies the change was
  # never supposed to reach.
  def items
    @model.rows(:items)
  end

  def item(id)
    items.find { |row| row[:id] == id }
  end

  def refused(query, changes, **options)
    error = assert_raises(Sodalite::DB::QueryError) { @model.update(query, changes, **options) }

    assert_equal UPDATE_SEED[:items], items
    assert_equal UPDATE_SEED[:orders], @model.rows(:orders)
    error
  end

  def test_set_replaces_the_value
    assert_equal 1, @model.update(UPDATE_SCHEMA[:items].where(:id, 1), { state: 'sold' })
    assert_equal 'sold', item(1)[:state]
    assert_equal UPDATE_SEED[:items].drop(1), items.drop(1)
  end

  def test_add_reads_the_value_it_replaces
    assert_equal 1, @model.update(UPDATE_SCHEMA[:items].where(:id, 2), { stock: Sodalite::DB.add(3) })
    assert_equal 7, item(2)[:stock]
  end

  # There is no `subtract`, so this is the decrement: one operation to judge, one
  # to compile, and one for three models to agree about.
  def test_a_signed_delta_is_the_decrement
    assert_equal 1, @model.update(UPDATE_SCHEMA[:items].where(:id, 2), { stock: Sodalite::DB.add(-3) })
    assert_equal 1, item(2)[:stock]
  end

  # Both kinds in one change, applied in the order they were declared.
  def test_a_set_and_an_add_are_one_update_of_one_row
    changed = @model.update(UPDATE_SCHEMA[:items].where(:id, 1),
                            { stock: Sodalite::DB.add(-1), state: 'sold' })

    assert_equal 1, changed
    assert_equal({ id: 1, name: 'lamp', stock: 0, score: 3, state: 'sold' }, item(1))
  end

  # The whole reason the operation exists. The guard is evaluated where the change
  # is applied, so the second decrement finds no row to apply to and the stock does
  # not go negative — where a select, a delete, and an insert would each have read
  # `1` and written `0`, losing one of the two decrements.
  def test_a_guard_that_no_longer_holds_changes_nothing
    guard = UPDATE_SCHEMA[:items].where(:id, 1).where(:stock, :gte, 1)

    assert_equal 1, @model.update(guard, { stock: Sodalite::DB.add(-1) })
    assert_equal 0, item(1)[:stock]
    assert_equal 0, @model.update(guard, { stock: Sodalite::DB.add(-1) })
    assert_equal 0, item(1)[:stock]
  end

  def test_a_subobject_that_names_nothing_is_honestly_zero
    assert_equal 0, @model.update(UPDATE_SCHEMA[:items].where(:state, 'gone'), { state: 'open' })
    assert_equal UPDATE_SEED[:items], items
  end

  def test_the_count_is_every_row_the_subobject_named
    assert_equal 2, @model.update(UPDATE_SCHEMA[:items].where(:state, 'open'), { state: 'held' })
    assert_equal %w[held held sold], items.map { |row| row[:state] }.sort
  end

  # The count is of rows the change was applied to, not of rows whose value came
  # out different. `add(0)` is the identity on a value and still a change applied
  # to a row, and rows-applied-to is what an `UPDATE` reports.
  def test_a_change_that_lands_on_the_value_already_there_still_counts_its_row
    sold = UPDATE_SCHEMA[:items].where(:id, 3)

    assert_equal 1, @model.update(sold, { state: 'sold' })
    assert_equal 1, @model.update(sold, { stock: Sodalite::DB.add(0) })
    assert_equal({ id: 3, name: 'rug', stock: 0, score: 7, state: 'sold' }, item(3))
  end

  # The rows an arrow hands back are copies — the value of an arrow is a
  # `Relation`, not a handle on the instance — so an update that wrote into them
  # would answer with a count and change nothing at all.
  def test_the_change_lands_in_the_store_and_not_in_a_copy_of_it
    named = @model.select(UPDATE_SCHEMA[:items].where(:id, 1)).rows

    assert_equal 1, @model.update(UPDATE_SCHEMA[:items].where(:id, 1), { stock: Sodalite::DB.add(9) })
    assert_equal 10, item(1)[:stock]
    assert_equal([1], named.map { |row| row[:stock] })
  end

  # --- what an update refuses, arriving before the store is touched -----------

  # Two of the twelve. The rest are pinned on the arrow itself in
  # `db_change_test.rb`; what the model adds is that a refusal reaches the caller
  # instead of an answer, and reaches it with the instance untouched.
  def test_an_image_is_not_a_set_of_rows
    message = refused(UPDATE_SCHEMA[:items].select(:name, :id), { name: 'x' }).message

    assert_match(/update needs a subobject of items/, message)
    assert_match(/select is not one/, message)
  end

  # The load-bearing one: a pullback's guard is a join, and evaluating it outside
  # the statement is the stale read this whole surface removes.
  def test_a_pullback_cannot_guard_an_update
    pulled = UPDATE_SCHEMA[:orders].where_at(:item, :state, 'open')

    assert_match(/cannot be guarded by a pullback/, refused(pulled, { item: 2 }).message)
  end

  # Composition moved the carrier, so this changes items and not orders. It is
  # meaningful, so it is allowed — once the caller has said so.
  def test_updating_through_a_composition_needs_the_carrier_named
    composed = UPDATE_SCHEMA[:orders].follow(:item)

    assert_match(/update over orders would change rows of items/, refused(composed, { state: 'sold' }).message)
    assert_equal 1, @model.update(composed, { state: 'sold' }, confirm_carrier: :items)
    assert_equal 'sold', item(1)[:state]
    assert_equal UPDATE_SEED[:items].drop(1), items.drop(1)
  end

  # --- a change inside a scope ------------------------------------------------

  # A change composes with the scope the way an insertion does: the snapshot was
  # taken on the way in, and an `Err` is what puts it back.
  def test_a_change_inside_a_scope_is_rolled_back_with_it
    result = @model.atomically do
      @model.update(UPDATE_SCHEMA[:items].where(:id, 1), { stock: Sodalite::DB.add(-1), state: 'sold' })
      Berylx::Focus[{}].reject(:conflict, 'no')
    end

    assert_instance_of Berylx::Err, result
    assert_equal UPDATE_SEED[:items], items
  end

  def test_a_change_inside_a_scope_that_does_not_fail_stands
    result = @model.atomically { @model.update(UPDATE_SCHEMA[:items].where(:id, 1), { state: 'sold' }) }

    assert_equal 1, result
    assert_equal 'sold', item(1)[:state]
  end

  # --- `add` on a `nothing` ---------------------------------------------------

  # The decision, and the one the other two models have to be held to. A nullable
  # column is a map into `A + 1` and `+ delta` is a function on `A`; the single
  # extension of it that leaves the coproduct alone fixes the adjoined point,
  # because there is no element there for a delta to be added to. So the row is a
  # row the change was applied to — it counts — and its value is still nothing.
  # It is also what the other two compute unaided, `NULL + 1` being `NULL`, so
  # three models agree here without a special case in any of them.
  def test_add_on_a_nothing_leaves_the_nothing_and_still_counts_the_row
    assert_equal 1, @model.update(UPDATE_SCHEMA[:items].where(:id, 2), { score: Sodalite::DB.add(1) })
    assert_nil item(2)[:score]
  end

  # `set` is how a value becomes nothing, and `add` cannot bring it back out: the
  # extension fixes the adjoined point whichever way the row arrived at it.
  def test_a_set_to_nothing_makes_every_later_add_the_identity
    query = UPDATE_SCHEMA[:items].where(:id, 1)

    assert_equal 1, @model.update(query, { score: nil })
    assert_equal 1, @model.update(query, { score: Sodalite::DB.add(5) })
    assert_nil item(1)[:score]
  end
end
