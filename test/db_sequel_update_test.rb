# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'
require 'logger'

begin
  require 'sqlite3'
  require 'sequel'
  SEQUEL_UPDATE_SQLITE = true
rescue LoadError
  SEQUEL_UPDATE_SQLITE = false
end

# What changing a value has to answer for on this model, which is mostly a claim
# about *statements*: one of them, with the guard inside it, and the new value
# written as a function of the old one rather than as something read into Ruby
# first. The conformance suite can check that the three models agree about the
# counts and the rows; only the log can say whether the shape that makes those
# counts safe is the shape that was issued.
#
# The schema is this file's own. `items.discount` is a nullable number, which is
# both what `add` over a `nothing` needs and what an order has to place.
class DBSequelUpdateTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(
    items: { id: :integer, name: :string, state: :string, stock: :integer, discount: :integer? },
    orders: { id: :integer, item: Sodalite::DB.fk(:items) }
  )

  SEED = {
    items: [
      { id: 1, name: 'salt', state: 'open', stock: 1, discount: 5 },
      { id: 2, name: 'pepper', state: 'open', stock: 4, discount: nil },
      { id: 3, name: 'sugar', state: 'sold', stock: 0, discount: 2 }
    ],
    orders: [{ id: 10, item: 2 }]
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless SEQUEL_UPDATE_SQLITE

    @db = Sequel.sqlite
    @model = Sodalite::DB.sequel(SCHEMA, @db).create_tables_for_test!
    SEED.each { |table, rows| rows.each { |row| @model.insert(table, row) } }
  end

  # The same reading `db_sequel_test.rb` takes: what the backend was handed,
  # rather than what it can be assumed to have been handed.
  def logged
    io = StringIO.new
    @db.loggers = [Logger.new(io)]
    yield
    io.string
  ensure
    @db.loggers = []
  end

  def item(id)
    @model.select(SCHEMA[:items].where(:id, id)).rows.first
  end

  # --- the two kinds ------------------------------------------------------

  # A `:set` is its operand and an `:add` is an expression over the column, so
  # the second one is computed where the row is rather than where the caller is.
  def test_a_set_assigns_and_an_add_is_computed_by_the_database
    assigned = logged { assert_equal 1, @model.update(SCHEMA[:items].where(:id, 1), { state: 'sold' }) }
    added = logged { assert_equal 1, @model.update(SCHEMA[:items].where(:id, 1), { stock: Sodalite::DB.add(2) }) }

    assert_includes assigned, "UPDATE `items` SET `state` = 'sold' WHERE (`id` = 1)"
    assert_includes added, 'UPDATE `items` SET `stock` = (`stock` + 2) WHERE (`id` = 1)'
    assert_equal({ id: 1, name: 'salt', state: 'sold', stock: 3, discount: 5 }, item(1))
  end

  # There is no `subtract`, and none is needed: the operand is signed, so the
  # decrement is the same arrow with the same law.
  def test_a_negative_delta_is_the_decrement
    sql = logged { assert_equal 1, @model.update(SCHEMA[:items].where(:id, 2), { stock: Sodalite::DB.add(-1) }) }

    assert_includes sql, 'UPDATE `items` SET `stock` = (`stock` + -1) WHERE (`id` = 2)'
    assert_equal 3, item(2)[:stock]
  end

  # Both kinds in one statement, in the order they were written — `Change.ordered`
  # is where that order comes from, and assignment being order-independent to a
  # database is not a reason for three models to emit three statements.
  def test_both_kinds_go_into_one_statement_in_the_order_they_were_written
    changes = { state: 'sold', stock: Sodalite::DB.add(-1) }
    sql = logged { assert_equal 1, @model.update(SCHEMA[:items].where(:id, 1), changes) }

    assert_equal 1, sql.lines.size
    assert_includes sql, "SET `state` = 'sold', `stock` = (`stock` + -1)"
    assert_equal({ id: 1, name: 'salt', state: 'sold', stock: 0, discount: 5 }, item(1))
  end

  # `NULL + 1` is `NULL`, so a change of a value that is not there leaves it not
  # there. The database is not talked out of that: an `add` is a function of the
  # old value, and over `A + 1` the old value was `nothing`. The row is still
  # matched and written, so the count is 1 — the count is of rows the statement
  # changed, not of values that came out different.
  def test_adding_to_a_nothing_leaves_nothing
    assert_equal 1, @model.update(SCHEMA[:items].where(:id, 2), { discount: Sodalite::DB.add(1) })
    assert_nil item(2)[:discount]
  end

  # --- the guard ----------------------------------------------------------

  # The whole point of the surface. The guard is evaluated by the statement that
  # applies the change, so a guard that has already fired does not fire again —
  # and the second caller is told it changed nothing instead of overwriting the
  # first caller's work with a value computed before it.
  def test_a_guard_that_has_already_fired_changes_nothing_the_second_time
    guarded = SCHEMA[:items].where(:id, 1).where(:stock, :gte, 1)
    changes = { stock: Sodalite::DB.add(-1), state: 'sold' }

    assert_equal 1, @model.update(guarded, changes)
    assert_equal 0, @model.update(guarded, changes)
    assert_equal({ id: 1, name: 'salt', state: 'sold', stock: 0, discount: 5 }, item(1))
  end

  # One statement, and nothing read before it. A select taken first is exactly
  # the stale read the operation exists to remove, so its absence is the thing
  # worth asserting rather than the count.
  def test_the_change_is_one_statement_with_no_select_before_it
    sql = logged { @model.update(SCHEMA[:items].where(:state, 'open'), { state: 'sold' }) }

    refute_includes sql, 'SELECT'
    assert_equal 1, sql.lines.size
  end

  # An arrow that names nothing is still one statement; it changes no rows and
  # says so. There is nothing to notice beforehand — noticing would be the select
  # this shape removed.
  def test_an_update_that_matches_nothing_is_one_statement_that_changes_no_rows
    sql = logged { assert_equal 0, @model.update(SCHEMA[:items].where(:name, 'no such item'), { state: 'sold' }) }

    assert_equal 1, sql.lines.size
    refute_includes sql, 'SELECT'
    assert_equal %w[open open sold], @model.select(SCHEMA[:items]).map { |row| row[:state] }.sort
  end

  # Composition moves the carrier, so this changes items and not orders. Allowed,
  # because it is meaningful — but the caller has to have said so, and the rows
  # are then named by the image of the arrow on the key rather than by a guard
  # the carrier's own table could evaluate.
  def test_a_change_through_a_composition_names_the_object_it_changes
    composed = SCHEMA[:orders].where(:id, 10).follow(:item)
    refused = assert_raises(Sodalite::DB::QueryError) { @model.update(composed, { state: 'sold' }) }

    assert_match(/pass confirm_carrier: :items to mean it/, refused.message)
    sql = logged { assert_equal 1, @model.update(composed, { state: 'sold' }, confirm_carrier: :items) }

    assert_equal 1, sql.lines.size
    assert_equal 'sold', item(2)[:state]
  end

  # The arrow is judged before anything is issued, which is what makes the
  # pullback refusal worth anything: a guard that cannot be evaluated inside the
  # statement never becomes a select taken before one.
  def test_a_refused_arrow_issues_no_statement_at_all
    pulled = SCHEMA[:orders].where_at(:item, :state, 'open')
    sql = logged { assert_raises(Sodalite::DB::QueryError) { @model.update(pulled, { id: 11 }) } }

    assert_empty sql
  end

  # --- the scope ----------------------------------------------------------

  # A change is a write like any other, so the scope's rule is the one every
  # write already follows: the caller never asks for a rollback, an `Err` is what
  # asks.
  def test_a_change_inside_a_scope_is_undone_when_the_scope_is_an_err
    result = @model.atomically do
      @model.update(SCHEMA[:items].where(:id, 1), { stock: Sodalite::DB.add(-1), state: 'sold' })
      Berylx::Focus[{}].reject(:conflict, 'no')
    end

    assert_instance_of Berylx::Err, result
    assert_equal({ id: 1, name: 'salt', state: 'open', stock: 1, discount: 5 }, item(1))
  end

  # --- where nothing goes -------------------------------------------------

  # `min`/`max` are monoids on `A + 1`, so a fold can answer `nothing` and an
  # order then has to place it. Left to the backends there is no answer — sqlite
  # sorts nulls first, postgres sorts them last — so it is decided: `nothing`
  # sorts after every element of A, in both directions.
  def test_nothing_sorts_after_every_element_in_both_directions
    ascending = @model.select(SCHEMA[:items].order(:discount))
    descending = @model.select(SCHEMA[:items].order(:discount, :desc))

    assert_equal([2, 5, nil], ascending.map { |row| row[:discount] })
    assert_equal([5, 2, nil], descending.map { |row| row[:discount] })
  end

  # And it is the same word on both, which is what "after, in both directions"
  # is: not "last ascending, first descending".
  def test_the_placement_is_spelled_the_same_way_in_both_directions
    ascending = logged { @model.select(SCHEMA[:items].order(:discount)) }
    descending = logged { @model.select(SCHEMA[:items].order(:discount, :desc)) }

    assert_includes ascending, 'ORDER BY `discount` ASC NULLS LAST, `id` ASC NULLS LAST'
    assert_includes descending, 'ORDER BY `discount` DESC NULLS LAST, `id` ASC NULLS LAST'
  end
end
