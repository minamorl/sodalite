# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  EQUATIONS_SQLITE = true
rescue LoadError
  EQUATIONS_SQLITE = false
end

# The presentation, and what it can now say that a graph could not.
#
# A schema holding only objects and generating morphisms is the *free* category
# on a graph, where no two distinct paths are ever equal. So
# `employee.manager.department = employee.department` — a constraint SQL's
# foreign keys genuinely cannot express, because a foreign key relates one column
# to one key and never one path to another — could not be written down at all.
# Declaring it is what makes the category finitely presented.
module EquationFixtures
  SPEC = {
    departments: { id: :integer, name: :string },
    employees: { id: :integer, name: :string,
                 department: Sodalite::DB.fk(:departments),
                 manager: Sodalite::DB.fk(:employees) }
  }.freeze

  # Two composites `employees -> departments`, declared equal.
  PRESENTED = Sodalite::DB.schema(SPEC, equations: [[:employees, %i[manager department], %i[department]]])

  # The same objects and morphisms with nothing said about their composites.
  FREE = Sodalite::DB.schema(SPEC)

  DEPARTMENTS = [{ id: 4, name: 'ops' }, { id: 7, name: 'eng' }].freeze

  # Every employee's manager is in the employee's own department.
  SATISFIED = {
    departments: DEPARTMENTS,
    employees: [
      { id: 1, name: 'mina', department: 4, manager: 1 },
      { id: 2, name: 'rin', department: 4, manager: 1 },
      { id: 5, name: 'ghost', department: 7, manager: 5 }
    ]
  }.freeze

  # Employee 3 is managed out of department 7 while sitting in department 4.
  VIOLATING = {
    departments: DEPARTMENTS,
    employees: [
      { id: 1, name: 'mina', department: 4, manager: 1 },
      { id: 3, name: 'kei', department: 4, manager: 5 },
      { id: 5, name: 'ghost', department: 7, manager: 5 }
    ]
  }.freeze

  # Employee 9's manager is a key nobody holds, so the composite has no value
  # there at all — a different failure from an equation that does not hold.
  DANGLING = {
    departments: DEPARTMENTS,
    employees: [
      { id: 1, name: 'mina', department: 4, manager: 1 },
      { id: 9, name: 'lost', department: 4, manager: 99 }
    ]
  }.freeze

  # Minimal adapter over sqlite3: `execute(sql, binds) -> rows`.
  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end

  # All three models over one instance, so a diagnostic can be asked of each in
  # the same breath.
  def models(schema, seed)
    memory = Sodalite::DB.memory(schema, seed)
    sql = Sodalite::DB.sql(schema, Adapter.new).create_tables_for_test!
    sequel = Sodalite::DB.sequel(schema, Sequel.sqlite).create_tables_for_test!
    seed.each { |table, rows| rows.each { |row| [sql, sequel].each { |model| model.insert(table, row) } } }
    [memory, sql, sequel]
  end
end

# Declaring an equation, and the presentations that are refused.
class DBEquationDeclarationTest < Minitest::Test
  include EquationFixtures

  def test_a_declared_equation_reads_back
    equation = PRESENTED.equations.first

    assert_equal 1, PRESENTED.equations.size
    assert_equal :employees, equation.from
    assert_equal %i[manager department], equation.left
    assert_equal %i[department], equation.right
    assert_equal 'employees.manager.department = employees.department', equation.to_s
  end

  # The source is named rather than inferred from the first morphism, so a
  # `manager` on two different objects is two different equations.
  def test_an_unknown_source_is_refused_naming_both_sides
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(SPEC, equations: [[:nobody, %i[manager department], %i[department]]])
    end

    assert_equal 'nobody.manager.department = nobody.department: no table :nobody', error.message
  end

  # A name that is not a morphism out of the object reached so far means the
  # path is not a path in this category, and the equation is about nothing.
  def test_a_name_that_is_not_a_morphism_is_refused_naming_both_sides
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(SPEC, equations: [[:employees, %i[manager boss], %i[department]]])
    end

    assert_equal 'employees.manager.boss = employees.department: employees has no morphism :boss',
                 error.message
  end

  # The check is against the object reached *so far*, not against the source:
  # `department` is a morphism out of employees and not out of departments.
  def test_a_name_that_is_a_morphism_of_the_wrong_object_is_refused
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(SPEC, equations: [[:employees, %i[department department], %i[department]]])
    end

    assert_equal 'employees.department.department = employees.department: ' \
                 'departments has no morphism :department', error.message
  end

  def test_two_paths_that_arrive_at_different_objects_are_refused_naming_both_sides
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(SPEC, equations: [[:employees, %i[manager], %i[department]]])
    end

    assert_equal 'employees.manager = employees.department: ' \
                 'manager arrives at employees, department at departments', error.message
  end

  # An empty path is allowed, and it is the identity: this says every employee
  # is their own manager. It is spelled by the key, because the key is the
  # column a model actually reads for it.
  def test_an_empty_path_is_the_identity_and_is_accepted
    schema = Sodalite::DB.schema(SPEC, equations: [[:employees, %i[manager], []]])

    assert_equal 'employees.manager = employees.id', schema.equations.first.to_s
    assert_empty schema.equations.first.right
  end

  def test_an_empty_path_is_still_judged_against_the_object_it_lands_on
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(SPEC, equations: [[:employees, %i[department], []]])
    end

    assert_equal 'employees.department = employees.id: ' \
                 'department arrives at departments, id at employees', error.message
  end

  # Strictly additive: a schema declared without equations is the schema that
  # was there before, down to the arrows it builds.
  def test_a_schema_without_equations_is_unchanged
    assert_empty FREE.equations
    assert_equal PRESENTED.names, FREE.names
    assert_equal PRESENTED.table(:employees).foreign_keys, FREE.table(:employees).foreign_keys
    assert_equal PRESENTED.table(:employees).column_type(:manager), FREE.table(:employees).column_type(:manager)
  end

  # The spec may be written bare or braced. Bare is how every schema in this
  # repository is spelled, and a keyword argument turns a bare trailing hash
  # into keywords, so both spellings are checked rather than assumed.
  def test_a_bare_spec_still_declares_a_schema
    bare = Sodalite::DB.schema(users: { id: :integer, name: :string })

    assert_equal %i[users], bare.names
    assert_empty bare.equations
  end
end

# The diagnostic: does the instance satisfy what the presentation declares?
#
# This is the same kind of question as `functor?` — a property the instance has
# or does not, reported rather than enforced — so the sentence lives on the
# schema and all three models say it identically.
class DBEquationViolationsTest < Minitest::Test
  include EquationFixtures

  def setup
    skip 'sqlite3 unavailable' unless EQUATIONS_SQLITE
  end

  def test_the_schema_spells_a_broken_equation
    message = PRESENTED.equation_message(PRESENTED.equations.first, 3, 7, 4)

    assert_equal 'employees.id=3: manager.department = 7 but department = 4', message
  end

  def test_every_model_reports_an_instance_that_satisfies_the_equation_as_clean
    models(PRESENTED, SATISFIED).each do |model|
      assert_empty model.equation_violations, model.class.name
      assert_predicate model, :satisfies_equations?
    end
  end

  # Byte-identical, because three lowerings — a walk in Set, a join, a dataset —
  # computing the same composites have to come back with one sentence or the
  # agreement between them is a claim nobody can read.
  def test_every_model_reports_a_broken_equation_in_the_same_sentence
    expected = ['employees.id=3: manager.department = 7 but department = 4']

    models(PRESENTED, VIOLATING).each do |model|
      assert_equal expected, model.equation_violations, model.class.name
      refute_predicate model, :satisfies_equations?
    end
  end

  # A missing image is not an equation violation. The composite has no value at
  # that element on either side, and an equation between two undefined
  # composites says nothing — the element is already reported, by `violations`,
  # because a morphism with no value at an element is what a dangling foreign
  # key is. Saying it twice would make one broken row look like two failures.
  def test_an_element_whose_composite_has_no_image_is_not_an_equation_violation
    models(PRESENTED, DANGLING).each do |model|
      assert_empty model.equation_violations, model.class.name
      assert_predicate model, :satisfies_equations?
      assert_equal ['employees.manager=99 has no employees'], model.violations, model.class.name
      refute_predicate model, :functor?
    end
  end

  # The identity equation, measured: the composite of the empty path at an
  # element is the element's own key, so this reports everyone who is not their
  # own manager.
  def test_every_model_measures_an_identity_equation_the_same_way
    schema = Sodalite::DB.schema(SPEC, equations: [[:employees, %i[manager], []]])
    expected = ['employees.id=2: manager = 1 but id = 2']

    models(schema, SATISFIED).each do |model|
      assert_equal expected, model.equation_violations, model.class.name
    end
  end

  def test_a_schema_with_no_equations_has_nothing_to_report
    models(FREE, VIOLATING).each do |model|
      assert_empty model.equation_violations, model.class.name
      assert_predicate model, :satisfies_equations?
    end
  end

  def test_the_hand_written_model_asks_in_one_statement
    statement = Sodalite::DB::SQL.equation_statement(PRESENTED, PRESENTED.equations.first)

    assert_equal 'SELECT "t0"."id", "t1"."department", "t0"."department" FROM "employees" "t0" ' \
                 'JOIN "employees" "t1" ON "t0"."manager" = "t1"."id" ' \
                 'WHERE "t1"."department" <> "t0"."department"', statement
  end
end

# The payoff: a path the schema proves equal to a shorter one is written as the
# shorter one.
class DBEquationNormalisationTest < Minitest::Test
  include EquationFixtures

  # `manager.department` is declared equal to `department`, so composing the two
  # morphisms emits one join instead of two. This is derived from the schema
  # rather than guessed at — and sound relative to the *declared theory*, which
  # `equation_violations` is how you check.
  def test_a_two_hop_path_collapses_to_the_one_it_is_equal_to
    collapsed = PRESENTED[:employees].follow(:manager).follow(:department)

    assert_equal [%i[follow department departments]], collapsed.steps
    assert_equal :departments, collapsed.carrier
    assert_equal 'SELECT DISTINCT "t1"."id", "t1"."name" FROM "employees" "t0" ' \
                 'JOIN "departments" "t1" ON "t0"."department" = "t1"."id"',
                 Sodalite::DB::SQL.compile(collapsed).first
  end

  def test_the_same_path_over_a_schema_without_equations_keeps_both_joins
    kept = FREE[:employees].follow(:manager).follow(:department)

    assert_equal [%i[follow manager employees], %i[follow department departments]], kept.steps
    assert_equal 'SELECT DISTINCT "t2"."id", "t2"."name" FROM "employees" "t0" ' \
                 'JOIN "employees" "t1" ON "t0"."manager" = "t1"."id" ' \
                 'JOIN "departments" "t2" ON "t1"."department" = "t2"."id"',
                 Sodalite::DB::SQL.compile(kept).first
  end

  # The rewrite is only sound relative to the declared theory, so it is worth
  # asking what it answers on an instance that satisfies the theory: the same
  # rows, in every model.
  def test_the_collapsed_arrow_answers_what_the_original_answers
    skip 'sqlite3 unavailable' unless EQUATIONS_SQLITE

    collapsed = PRESENTED[:employees].follow(:manager).follow(:department)
    original = FREE[:employees].follow(:manager).follow(:department)
    expected = Sodalite::DB.memory(FREE, SATISFIED).select(original)

    assert_equal [{ id: 4, name: 'ops' }, { id: 7, name: 'eng' }].to_set, expected.rows.to_set
    models(PRESENTED, SATISFIED).each do |model|
      assert_equal expected, model.select(collapsed), model.class.name
    end
  end

  # Re-checked after each rewrite, so a chain collapses more than once:
  # `up.root.root` -> `root.root` -> `root`.
  def test_a_chain_of_equations_collapses_more_than_once
    schema = Sodalite::DB.schema(
      { nodes: { id: :integer, up: Sodalite::DB.fk(:nodes), root: Sodalite::DB.fk(:nodes) } },
      equations: [[:nodes, %i[up root], %i[root]], [:nodes, %i[root root], %i[root]]]
    )

    collapsed = schema[:nodes].follow(:up).follow(:root).follow(:root)

    assert_equal [%i[follow root nodes]], collapsed.steps
    assert_equal :nodes, collapsed.carrier
  end

  # An equation whose sides are the same length proves nothing about length.
  # Rewriting one onto the other would shrink nothing and could be undone by the
  # same equation forever, so it is skipped rather than applied.
  def test_an_equation_whose_sides_are_the_same_length_does_not_loop
    schema = Sodalite::DB.schema(
      { nodes: { id: :integer, up: Sodalite::DB.fk(:nodes), alt: Sodalite::DB.fk(:nodes) } },
      equations: [[:nodes, %i[up], %i[alt]]]
    )

    kept = schema[:nodes].follow(:up).follow(:alt)

    assert_equal [%i[follow up nodes], %i[follow alt nodes]], kept.steps
  end

  # An empty shorter side drops the composition entirely, which is what
  # `manager = id` means — and `distinct?` follows it down, because the image is
  # already taken once no morphism repeats a row.
  def test_a_rewrite_onto_the_identity_drops_the_composition
    schema = Sodalite::DB.schema(SPEC, equations: [[:employees, %i[manager], []]])

    collapsed = schema[:employees].follow(:manager)

    assert_empty collapsed.steps
    assert_equal :employees, collapsed.carrier
    refute_predicate collapsed, :distinct?
    assert_equal 'SELECT "t0"."id", "t0"."name", "t0"."department", "t0"."manager" FROM "employees" "t0"',
                 Sodalite::DB::SQL.compile(collapsed).first
  end

  # Only a suffix of the *trailing* run is looked at. A subobject between two
  # compositions was taken on the object the run had reached, so rewriting
  # across it would move that subobject to a different object.
  def test_a_subobject_between_two_compositions_breaks_the_run
    kept = PRESENTED[:employees].follow(:manager).where(:name, 'mina').follow(:department)

    assert_equal [%i[follow manager employees], [:where, :name, 'mina', :eq],
                  %i[follow department departments]], kept.steps
  end

  # The suffix has to start at the object the equation was declared out of.
  # Two objects can carry the same morphism name, so the object is half of the
  # match rather than a detail of it.
  def test_a_suffix_that_starts_at_another_object_does_not_match
    schema = Sodalite::DB.schema(
      {
        rooms: { id: :integer, floor: Sodalite::DB.fk(:floors) },
        desks: { id: :integer, room: Sodalite::DB.fk(:rooms), floor: Sodalite::DB.fk(:floors) },
        floors: { id: :integer, name: :string }
      },
      equations: [[:desks, %i[room floor], %i[floor]]]
    )

    assert_equal [%i[follow floor floors]], schema[:desks].follow(:room).follow(:floor).steps
    assert_equal [%i[follow floor floors]], schema[:rooms].follow(:floor).steps
  end
end
