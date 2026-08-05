# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  UPDATE_SQLITE = true
rescue LoadError
  UPDATE_SQLITE = false
end

# What a change compiles to, read as a value with no database in the room.
#
# The text is the claim here. A change is safe because the guard is evaluated
# *inside* the statement that applies it and because `:add` names the column on
# both sides — neither of which a conformance suite can see, since three models
# agreeing about the rows they end up with is exactly what a lost update looks
# like when nothing is concurrent.
class DBSqlUpdateStatementTest < Minitest::Test
  # `tag` is a map into `A + 1`, so a guard can eliminate the `+ 1`; `orders` is
  # the morphism a change can be guarded across.
  SCHEMA = Sodalite::DB.schema(
    items: { id: :integer, name: :string, stock: :integer, tag: :string? },
    orders: { id: :integer, item: Sodalite::DB.fk(:items) }
  )

  # Every name here is reserved somewhere, including the column being assigned:
  # a change is emitted through the same quoting as everything else, or a schema
  # is not free to name a column `group`.
  RESERVED = Sodalite::DB.schema(order: { id: :integer, select: :string, group: :integer })

  def compile(query, changes) = Sodalite::DB::SQL.update_statement(query, changes)

  # --- what a change is -----------------------------------------------------

  def test_a_set_assigns_a_value_the_statement_carries
    sql, binds = compile(SCHEMA[:items], { name: 'ghost' })

    assert_equal 'UPDATE "items" SET "name" = ?', sql
    assert_equal ['ghost'], binds
  end

  # The whole reason the vocabulary is closed. The column is on both sides, so
  # the engine computes the new value from whatever the old one is by the time
  # it holds the row — there is no earlier read for a second scope to have
  # overwritten.
  def test_an_add_is_computed_by_the_engine_from_the_value_it_replaces
    sql, binds = compile(SCHEMA[:items], { stock: Sodalite::DB.add(1) })

    assert_equal 'UPDATE "items" SET "stock" = "stock" + ?', sql
    assert_equal [1], binds
  end

  # A decrement is `add` of a negative delta, so there is one operation to
  # compile rather than two spellings of one arrow.
  def test_a_decrement_is_the_same_statement_with_a_signed_operand
    sql, binds = compile(SCHEMA[:items], { stock: Sodalite::DB.add(-1) })

    assert_equal 'UPDATE "items" SET "stock" = "stock" + ?', sql
    assert_equal [-1], binds
  end

  # Declaration order is the order, because the models are compared by what they
  # emit and three readings of one Hash would be three statements for one change.
  def test_both_kinds_at_once_keep_the_order_the_hash_was_written_in
    sql, binds = compile(SCHEMA[:items], { name: 'restocked', stock: Sodalite::DB.add(2) })

    assert_equal 'UPDATE "items" SET "name" = ?, "stock" = "stock" + ?', sql
    assert_equal ['restocked', 2], binds

    reversed, = compile(SCHEMA[:items], { stock: Sodalite::DB.add(2), name: 'restocked' })

    assert_equal 'UPDATE "items" SET "stock" = "stock" + ?, "name" = ?', reversed
  end

  # --- the guard ------------------------------------------------------------

  # Inside the statement, and the assignment's binds come first because that is
  # the order the placeholders appear in.
  def test_the_guard_is_the_arrows_own_subobject_inside_the_statement
    sql, binds = compile(SCHEMA[:items].where(:id, 1).where(:stock, :gt, 0), { stock: Sodalite::DB.add(-1) })

    assert_equal 'UPDATE "items" SET "stock" = "stock" + ? WHERE "id" = ? AND "stock" > ?', sql
    assert_equal [-1, 1, 0], binds
  end

  # Eliminating the `+ 1` is a guard like any other; it just binds nothing.
  def test_an_elimination_of_a_nullable_column_guards_without_a_bind
    sql, binds = compile(SCHEMA[:items].where_null(:tag), { name: 'untagged' })

    assert_equal 'UPDATE "items" SET "name" = ? WHERE "tag" IS NULL', sql
    assert_equal ['untagged'], binds

    present, = compile(SCHEMA[:items].where_present(:tag), { name: 'tagged' })

    assert_equal 'UPDATE "items" SET "name" = ? WHERE "tag" IS NOT NULL', present
  end

  # A composition's guard is a join, and a join inside an `UPDATE` is
  # dialect-bound — so it goes in a subquery and the statement names its rows by
  # the key. Still one statement, and the guard is still the engine's to
  # evaluate rather than a key list read into Ruby and sent back.
  def test_a_guard_across_a_morphism_stays_in_the_statement_as_a_subquery
    sql, binds = compile(SCHEMA[:orders].where(:id, 10).follow(:item), { stock: Sodalite::DB.add(-1) })

    assert_equal 'UPDATE "items" SET "stock" = "stock" + ? WHERE "id" IN (SELECT "t1"."id" ' \
                 'FROM "orders" "t0" JOIN "items" "t1" ON "t0"."item" = "t1"."id" WHERE "t0"."id" = ?)', sql
    assert_equal [-1, 10], binds
  end

  # --- quoting --------------------------------------------------------------

  def test_every_identifier_a_change_emits_is_quoted
    sql, binds = compile(RESERVED[:order].where(:select, 'x'), { group: Sodalite::DB.add(1) })

    assert_equal 'UPDATE "order" SET "group" = "group" + ? WHERE "select" = ?', sql
    assert_equal [1, 'x'], binds
  end

  # --- the statements beside it ---------------------------------------------

  # The deletion a connection that counts its own changes runs: the same guard,
  # and no key list at all.
  def test_a_deletion_by_its_guard_names_no_keys
    assert_equal ['DELETE FROM "items" WHERE "stock" = ?', [0]],
                 Sodalite::DB::SQL.delete_statement(SCHEMA[:items].where(:stock, 0))
    assert_equal ['DELETE FROM "items" WHERE "id" IN (SELECT "t1"."id" FROM "orders" "t0" ' \
                  'JOIN "items" "t1" ON "t0"."item" = "t1"."id" WHERE "t0"."id" = ?)', [10]],
                 Sodalite::DB::SQL.delete_statement(SCHEMA[:orders].where(:id, 10).follow(:item))
  end

  # The measurement a connection without that method needs, over the same guard,
  # so the count and the statement cannot name different sets.
  def test_the_measurement_is_taken_over_the_same_guard
    assert_equal ['SELECT COUNT(*) FROM "items" WHERE "stock" > ?', [0]],
                 Sodalite::DB::SQL.count_statement(SCHEMA[:items].where(:stock, :gt, 0))
  end
end

# The half of a change that is not text: how many rows it applied to, and what
# it costs to find that out. Both need a database, so they live with the model.
class DBSqlUpdateModelTest < Minitest::Test
  SCHEMA = DBSqlUpdateStatementTest::SCHEMA

  SEED = {
    items: [{ id: 1, name: 'last one', stock: 1, tag: nil },
            { id: 2, name: 'plenty', stock: 5, tag: 'fresh' },
            { id: 3, name: 'gone', stock: 0, tag: nil }],
    orders: [{ id: 10, item: 1 }, { id: 11, item: 3 }]
  }.freeze

  # The mandatory port, with a tape on it: `execute(sql, binds) -> rows` and no
  # affected-row count anywhere in it.
  class Tape
    attr_reader :statements

    def initialize
      @db = SQLite3::Database.new(':memory:')
      @statements = []
    end

    def execute(sql, binds)
      @statements << sql
      @db.execute(sql, binds)
    end
  end

  # The same connection declaring the optional half. `change` is the one thing
  # `execute` cannot report, and declaring it is a capability rather than a
  # requirement — which is why both connections here are whole connections.
  class Counting < Tape
    def change(sql, binds)
      execute(sql, binds)
      @db.changes
    end
  end

  # Two whole connections over the same schema and the same rows, differing only
  # in whether they declare the second method — so every claim below is a claim
  # about the two readings of the port and not about two databases.
  def setup
    skip 'sqlite3 unavailable' unless UPDATE_SQLITE

    @tape = Tape.new
    @counter = Counting.new
    @measured = seeded(@tape)
    @counted = seeded(@counter)
  end

  def seeded(connection)
    model = Sodalite::DB.sql(SCHEMA, connection).create_tables_for_test!
    SEED.each { |table, rows| rows.each { |row| model.insert(table, row) } }
    connection.statements.clear
    model
  end

  def models = [@measured, @counted]

  def stocks(model) = (1..3).map { |id| model.select(SCHEMA[:items].where(:id, id)).rows.first[:stock] }

  def ids(model, table) = model.select(SCHEMA[table]).map { |row| row[:id] }.sort

  # --- what the second method buys ------------------------------------------

  # One statement, and nothing before it. The reading it replaces has to know
  # the subobject's size, and the only way to learn that through `execute` is to
  # ask for it.
  def test_a_connection_that_counts_its_changes_emits_the_update_and_nothing_else
    @counted.update(SCHEMA[:items].where(:id, 2), { stock: Sodalite::DB.add(-1) })

    assert_equal ['UPDATE "items" SET "stock" = "stock" + ? WHERE "id" = ?'], @counter.statements
    assert_empty @counter.statements.grep(/\ASELECT/)
  end

  # The measured reading counts the guard *before* the statement, because a
  # change moves rows out of the subobject that named them: `stock = stock - 1`
  # under `stock > 0` is exactly that, and counting afterwards would count a
  # different set. Both readings are in one scope, so nothing else can move a
  # row between them.
  def test_a_connection_with_only_execute_measures_the_guard_in_the_same_scope
    @measured.update(SCHEMA[:items].where(:stock, :gt, 0), { stock: Sodalite::DB.add(-1) })

    assert_equal(%w[BEGIN SELECT UPDATE COMMIT], @tape.statements.map { |sql| sql.split.first })
    assert_includes @tape.statements[1], 'SELECT COUNT(*) FROM "items" WHERE "stock" > ?'
  end

  # --- the two readings answer the same thing -------------------------------

  def test_both_readings_of_the_port_answer_with_the_same_count
    counts = models.map do |model|
      model.update(SCHEMA[:items].where(:stock, :gt, 0), { stock: Sodalite::DB.add(-1) })
    end

    assert_equal [2, 2], counts
    assert_equal([[0, 4, 0]] * 2, models.map { |model| stocks(model) })
  end

  def test_both_readings_leave_the_same_rows_after_a_set
    models.each do |model|
      assert_equal 2, model.update(SCHEMA[:items].where_null(:tag), { tag: 'plain' })
      assert_equal(%w[fresh plain plain], model.select(SCHEMA[:items]).map { |row| row[:tag] }.sort)
    end
  end

  # A guard that names nothing is a subobject too — the empty one — so the
  # answer is a count, not a refusal.
  def test_a_guard_that_names_nothing_changes_nothing_and_says_so
    counts = models.map do |model|
      model.update(SCHEMA[:items].where(:name, 'ghost'), { stock: Sodalite::DB.add(-1) })
    end

    assert_equal [0, 0], counts
    assert_equal([[1, 5, 0]] * 2, models.map { |model| stocks(model) })
  end

  # --- what the count is for ------------------------------------------------

  # The payoff, stated as a test. Two scopes decrementing the last unit is the
  # case `SELECT`, `DELETE`, `INSERT` inside one transaction gets wrong under
  # READ COMMITTED: both read `stock = 1`, both write `0`, and one decrement is
  # lost. Here the guard is evaluated by the engine while it holds the row, so
  # the second finds no row in the subobject — and the `0` it answers with is
  # how the caller learns it lost, without reading anything back.
  def test_two_guarded_decrements_from_one_leave_zero_and_the_second_says_it_lost
    guarded = SCHEMA[:items].where(:id, 1).where(:stock, :gt, 0)

    models.each do |model|
      assert_equal 1, model.update(guarded, { stock: Sodalite::DB.add(-1) })
      assert_equal 0, model.update(guarded, { stock: Sodalite::DB.add(-1) })
      assert_equal [0, 5, 0], stocks(model)
    end
  end

  # --- the arrow is judged first --------------------------------------------

  # An update names rows of the carrier the same way a deletion does, so it
  # inherits every refusal — and it adds the one a deletion has no reason for:
  # a pullback's guard is a join, and evaluating it would mean a `SELECT` taken
  # before the statement, which is the stale read this operation exists to
  # remove. Both refusals land before anything is emitted, which is why nothing
  # was emitted.
  def test_an_arrow_that_cannot_carry_a_change_is_refused_before_any_statement
    models.zip([@tape, @counter]).each do |model, connection|
      assert_raises(Sodalite::DB::QueryError) { model.update(SCHEMA[:items].select(:name), { name: 'x' }) }
      assert_raises(Sodalite::DB::QueryError) do
        model.update(SCHEMA[:orders].where_at(:item, :stock, 0), { item: 2 })
      end
      assert_empty connection.statements
    end
  end

  # The carrier moves with a composition, so changing rows of the codomain is
  # said out loud or it is refused — and once it is said, both readings change
  # the same rows through the subquery the guard becomes.
  def test_both_readings_change_the_same_rows_through_a_composition
    moved = SCHEMA[:orders].where(:id, 10).follow(:item)

    models.each do |model|
      assert_raises(Sodalite::DB::QueryError) { model.update(moved, { stock: Sodalite::DB.add(-1) }) }
      assert_equal 1, model.update(moved, { stock: Sodalite::DB.add(-1) }, confirm_carrier: :items)
      assert_equal [0, 5, 0], stocks(model)
    end
  end

  # --- the same widening, on the deletion -----------------------------------

  # The doomed rows are never read: the arrow's own guard is what the `DELETE`
  # carries, so there is no key list, no chunking, and one statement regardless
  # of how many rows are in the subobject.
  def test_a_deletion_on_the_counting_port_is_one_statement_with_no_key_list
    assert_equal 2, @counted.delete(SCHEMA[:items].where(:stock, :lte, 1))
    assert_equal ['DELETE FROM "items" WHERE "stock" <= ?'], @counter.statements
  end

  def test_both_readings_of_the_port_remove_the_same_rows_and_count_them_alike
    assert_equal([2, 2], models.map { |model| model.delete(SCHEMA[:items].where(:stock, :lte, 1)) })
    assert_equal([[2]] * 2, models.map { |model| ids(model, :items) })
  end

  def test_both_readings_remove_the_same_rows_through_a_composition
    moved = SCHEMA[:orders].where(:id, 10).follow(:item)

    assert_equal([1, 1], models.map { |model| model.delete(moved, confirm_carrier: :items) })
    assert_equal([[2, 3]] * 2, models.map { |model| ids(model, :items) })
  end

  # A pullback does not move the carrier, so a deletion through one removes rows
  # of the object that was asked about — on both readings, and the counting one
  # gets there without naming a single key.
  def test_both_readings_remove_the_same_rows_through_a_pullback
    assert_equal([1, 1], models.map { |model| model.delete(SCHEMA[:orders].where_at(:item, :stock, 0)) })
    assert_equal([[10]] * 2, models.map { |model| ids(model, :orders) })
  end
end
