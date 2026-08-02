# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  DDL_SQLITE = true
rescue LoadError
  DDL_SQLITE = false
end

# `DDL.ddl` dispatches on a closed set of step kinds. A kind that falls through
# every branch answers `nil`, and the caller's `.each` turns that into a
# `NoMethodError` at migration time — the one place this design promises not to
# fail. `rename_table` was exactly that hole: declared in `STEP_KINDS`, carried
# by the Sequel model, and absent from the hand-written one.
#
# So the check is not "rename_table works" but "the case is total": every kind
# the ledger accepts produces statements. A kind added later without DDL fails
# here rather than at 3am.
class DBDDLTest < Minitest::Test
  SPEC = { users: { id: :integer, name: :string } }.freeze
  PAIR = { cats: { id: :integer, name: :string }, dogs: { id: :integer, name: :string } }.freeze
  TAGGED = { animals: { id: :integer, name: :string, species: :string } }.freeze

  CASES = {
    create_table: [{}, [:create_table, :users, { id: :integer, name: :string }]],
    drop_table: [SPEC, %i[drop_table users]],
    add_attribute: [SPEC, [:add_attribute, :users, :city, :string, 'unknown']],
    drop_attribute: [SPEC, %i[drop_attribute users name]],
    rename_attribute: [SPEC, %i[rename_attribute users name handle]],
    rename_table: [SPEC, %i[rename_table users people]],
    merge_tables: [PAIR, [:merge_tables, %i[cats dogs], :animals, :species]],
    split_table: [TAGGED, [:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }]]
  }.freeze

  # If a step kind is added without a case here, this is the assertion that says so.
  def test_every_declared_step_kind_is_covered_by_a_case
    assert_equal Sodalite::DB::STEP_KINDS.sort, CASES.keys.sort
  end

  def test_every_step_kind_produces_statements
    CASES.each do |kind, (spec, args)|
      step = Sodalite::DB::Step[*args]
      schema = Sodalite::DB::Schema.new(step.apply(spec))
      statements = Sodalite::DB::DDL.ddl(step, schema)

      refute_nil statements, "#{kind}: DDL が無い"
      refute_empty statements, "#{kind}: DDL が空"
      statements.each do |sql, binds|
        assert_kind_of String, sql, "#{kind}: SQL が String でない"
        assert_kind_of Array, binds, "#{kind}: binds が Array でない"
      end
    end
  end

  # The statements are run against a real database rather than compared as text,
  # because "it produced a string" is not the claim — the claim is that the rows
  # are still there under the new name.
  def test_a_renamed_table_keeps_its_rows
    skip 'sqlite3 unavailable' unless DDL_SQLITE

    db = SQLite3::Database.new(':memory:')
    db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)')
    db.execute("INSERT INTO users (id, name) VALUES (1, 'mina')")

    step = Sodalite::DB::Step[:rename_table, :users, :people]
    schema = Sodalite::DB::Schema.new(step.apply(SPEC))
    Sodalite::DB::DDL.ddl(step, schema).each { |sql, binds| db.execute(sql, binds) }

    assert_equal [[1, 'mina']], db.execute('SELECT id, name FROM people')
  end
end
