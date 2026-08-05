# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# The lost update, and the shape that removes it.
#
# Read the row, delete it, insert the changed version, all inside `atomically`:
# atomic, and not serialisable under READ COMMITTED, which is what a plain
# `BEGIN` gets. Two scopes read `stock = 1`, the second's delete blocks, wakes,
# re-evaluates its guard against a row already gone, removes nothing, and writes
# a value it computed before any of that. The decrement is lost.
#
# A fifth operation that assigned literals would lose it in exactly the same way,
# so what is tested here is the property that actually removes it: a change is a
# function of the value it replaces, and its guard is evaluated in the statement
# that applies it. Every refusal below is a way that property could be broken.
CHANGE_SCHEMA = Sodalite::DB.schema(
  items: { id: :integer, name: :string, stock: :integer, price: :float?, state: :string },
  orders: { id: :integer, item: Sodalite::DB.fk(:items) }
)

# A closed vocabulary of two, not an expression language — the same rule that
# kept `avg` out of the aggregates.
class DBChangeVocabularyTest < Minitest::Test
  def test_add_is_a_change_that_reads_the_old_value
    change = Sodalite::DB.add(-1)

    assert_equal :add, change.kind
    assert_equal(-1, change.operand)
  end

  # No `subtract`: a decrement is `add` of a negative delta, so there is one
  # operation to judge, one to compile, and one for three models to agree about.
  def test_a_decrement_is_add_of_a_negative_delta
    assert_equal Sodalite::DB.add(-1), Sodalite::DB::Change[:add, -1]
  end

  def test_set_is_a_change_that_does_not
    change = Sodalite::DB.set('sold')

    assert_equal :set, change.kind
    assert_equal 'sold', change.operand
  end

  # `{ state: 'sold' }` and `{ state: DB.set('sold') }` are one change, and the
  # rule saying so is written once so that three models cannot spell it three
  # ways — a difference that would only ever show on the bare form.
  def test_a_bare_value_is_a_set
    assert_equal Sodalite::DB.set('sold'), Sodalite::DB::Change.of('sold')
  end

  def test_a_bare_value_that_is_nil_or_false_is_still_a_set
    assert_equal Sodalite::DB::Change[:set, nil], Sodalite::DB::Change.of(nil)
    assert_equal Sodalite::DB::Change[:set, false], Sodalite::DB::Change.of(false)
  end

  # Idempotent, so a caller that has already normalised does not have to remember
  # whether it did.
  def test_normalising_a_change_is_the_change
    %i[set add].each do |kind|
      change = Sodalite::DB::Change[kind, 1]

      assert_same change, Sodalite::DB::Change.of(change)
    end
  end

  # The one reading of a changes Hash. Declaration order is the order and it is
  # fixed: three readings of one Hash would be three statements for one change.
  def test_the_ordered_reading_keeps_declaration_order
    reading = Sodalite::DB::Change.ordered(state: 'sold', stock: Sodalite::DB.add(-1))

    assert_equal %i[state stock], reading.map(&:first)
    assert_equal [Sodalite::DB.set('sold'), Sodalite::DB.add(-1)], reading.map(&:last)
  end

  def test_the_ordered_reading_normalises_the_field_and_the_change
    reading = Sodalite::DB::Change.ordered('state' => 'sold')

    assert_equal [[:state, Sodalite::DB.set('sold')]], reading
  end

  def test_the_ordered_reading_of_nothing_is_nothing
    assert_empty Sodalite::DB::Change.ordered({})
  end
end

# Updating through an arrow names rows of the carrier the same way deleting does,
# so it inherits every refusal `deletable!` makes — and adds the ones that are
# about where the guard is evaluated and about what a change may be.
class DBUpdatableTest < Minitest::Test
  def guarded
    CHANGE_SCHEMA[:items].where(:state, 'open')
  end

  def refused(query, changes, **options)
    assert_raises(Sodalite::DB::QueryError) { query.updatable!(changes, **options) }
  end

  def test_a_guarded_update_on_the_carrier_is_updatable
    query = guarded

    assert_same query, query.updatable!({ stock: Sodalite::DB.add(-1), state: 'sold' })
  end

  def test_add_is_a_change_of_a_type_that_carries_addition
    query = CHANGE_SCHEMA[:items]

    assert_same query, query.updatable!({ stock: Sodalite::DB.add(-1) })
  end

  # The nullable spelling is the same type over `A + 1`, so it carries the same
  # addition and is not listed twice.
  def test_add_is_a_change_of_the_nullable_spelling_too
    query = guarded

    assert_same query, query.updatable!({ price: Sodalite::DB.add(1.5) })
  end

  def test_set_is_a_change_of_a_type_that_carries_nothing_in_particular
    query = guarded

    assert_same query, query.updatable!({ name: 'kept', state: Sodalite::DB.set('sold') })
  end

  # --- what a deletion refuses, refused here under its own name ---------------

  def test_an_image_is_not_a_set_of_rows
    message = refused(CHANGE_SCHEMA[:items].select(:name), { name: 'x' }).message

    assert_match(/update needs a subobject of items/, message)
    assert_match(/select is not one/, message)
  end

  def test_a_fold_is_not_a_set_of_rows
    folded = CHANGE_SCHEMA[:items].group(:state).count(:many)

    assert_match(/group is not one/, refused(folded, { name: 'x' }).message)
  end

  def test_a_coproduct_is_not_a_set_of_rows
    united = CHANGE_SCHEMA[:items].where(:id, 1).union(CHANGE_SCHEMA[:items].where(:id, 2))

    assert_match(/union is not one/, refused(united, { name: 'x' }).message)
  end

  def test_a_window_is_not_a_subobject
    assert_match(/order is not one/, refused(CHANGE_SCHEMA[:items].order(:name), { name: 'x' }).message)
    assert_match(/limit is not one/, refused(CHANGE_SCHEMA[:items].with(limit_rows: 1), { name: 'x' }).message)
    assert_match(/offset is not one/, refused(CHANGE_SCHEMA[:items].with(offset_rows: 1), { name: 'x' }).message)
  end

  # Composition moved the carrier, so this changes items and not orders. Allowed,
  # because it is meaningful — but only once the caller has said it.
  def test_updating_through_a_composition_needs_the_carrier_named
    composed = CHANGE_SCHEMA[:orders].follow(:item)
    message = refused(composed, { state: 'sold' }).message

    assert_match(/update over orders would change rows of items/, message)
    assert_match(/confirm_carrier: :items/, message)
    assert_same composed, composed.updatable!({ state: 'sold' }, confirm_carrier: :items)
  end

  def test_naming_the_object_the_arrow_left_is_still_refused
    refused(CHANGE_SCHEMA[:orders].follow(:item), { state: 'sold' }, confirm_carrier: :orders)
  end

  # --- and what only an update refuses ----------------------------------------

  # The load-bearing one. A pullback's guard is a join, a join inside an `UPDATE`
  # is dialect-bound, and the portable way out is to evaluate the guard in a
  # `SELECT` taken earlier — which is the stale read this whole surface removes.
  def test_a_pullback_cannot_guard_an_update
    pulled = CHANGE_SCHEMA[:orders].where_at(:item, :state, 'open')
    message = refused(pulled, { id: 1 }).message

    assert_match(/cannot be guarded by a pullback/, message)
    assert_match(/inside the update statement/, message)
    assert_match(/dialect-bound/, message)
    assert_match(/lost update/, message)
  end

  def test_a_pullback_is_refused_however_long_its_path_is
    composed = Sodalite::DB.schema(
      items: { id: :integer, state: :string },
      orders: { id: :integer, item: Sodalite::DB.fk(:items) },
      lines: { id: :integer, order: Sodalite::DB.fk(:orders) }
    )

    assert_match(/pullback/,
                 refused(composed[:lines].where_along(%i[order item], :state, 'open'), { id: 1 }).message)
  end

  def test_a_change_of_nothing_is_not_a_change
    message = refused(guarded, {}).message

    assert_match(/needs a change/, message)
    assert_match(/the identity/, message)
  end

  def test_a_field_that_is_not_a_field_of_the_carrier_is_not_a_change_of_it
    assert_match(/items has no field :colour/, refused(guarded, { colour: 'red' }).message)
  end

  # Identity is not a value to reassign: move it and the models each answer about
  # a different row from the one they named.
  def test_the_key_is_not_a_value_to_reassign
    message = refused(guarded, { id: 2 }).message

    assert_match(/items\.id is the identity of a row/, message)
    assert_match(/which row they changed/, message)
  end

  # Judged on the type, the way an order comparison is, and the refusal says what
  # the type was.
  def test_add_on_a_type_that_carries_no_addition_is_refused
    message = refused(guarded, { state: Sodalite::DB.add('x') }).message

    assert_match(/items\.state is :string/, message)
    assert_match(/carries no addition/, message)
  end

  def test_add_on_a_foreign_key_column_is_refused_by_the_targets_key_type
    keyed = Sodalite::DB.schema(
      accounts: { id: :string, name: :string },
      sessions: { id: :integer, account: Sodalite::DB.fk(:accounts) }
    )

    assert_match(/sessions\.account is :string/, refused(keyed[:sessions], { account: Sodalite::DB.add(1) }).message)
  end

  # A set of the same column is fine — it is only addition the type has to carry.
  def test_set_on_a_type_that_carries_no_addition_is_a_change
    query = guarded

    assert_same query, query.updatable!({ state: Sodalite::DB.set('sold') })
  end
end

# The signature was fixed at four operations and is five now, so the tag and its
# handler are checked the way the other four are: present, once, and in the shape
# a model will be called with.
class DBUpdateEffectTest < Minitest::Test
  def test_the_tag_is_in_the_signature_exactly_once
    assert_equal 1, Sodalite::DB::TAGS.count(Sodalite::DB::UPDATE)
    assert_equal :sodalite_db_update, Sodalite::DB::UPDATE
  end

  def test_the_tag_sits_between_insert_and_delete
    assert_equal %i[sodalite_db_select sodalite_db_insert sodalite_db_update
                    sodalite_db_delete sodalite_db_atomically],
                 Sodalite::DB::TAGS
  end

  # The handler is a one-argument lambda over the `[query, changes]` payload, the
  # way `INSERT` is one over `[table, row]`. It is not called: no model answers
  # `update` yet, and this is the phase that fixes the tag rather than the one
  # that fixes the models.
  def test_a_capability_exposes_a_handler_for_every_tag
    effects = Sodalite::DB.capability(Object.new).effects(->(_) {})

    assert_equal Sodalite::DB::TAGS.sort, effects.keys.sort
  end

  def test_the_update_handler_takes_one_payload
    handler = Sodalite::DB.capability(Object.new).effects(->(_) {}).fetch(Sodalite::DB::UPDATE)

    assert_equal 1, handler.arity
  end
end
