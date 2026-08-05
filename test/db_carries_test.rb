# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# `Σ_F` and its decomposition are the two steps whose induced map on instances
# can fail to exist, and they fail in ways the models used to disagree about: the
# in-memory model raised from inside `fetch` after emptying the targets, the SQL
# model deleted the rows it had no fibre for. A step that has no induced map is
# refused before either model starts, with one sentence.
class DBCarriesTest < Minitest::Test
  ANIMALS = Sodalite::DB.schema(animals: { id: :integer, name: :string, species: :string })
  PETS = Sodalite::DB.schema(cats: { id: :integer, name: :string }, dogs: { id: :integer, name: :string })
  SPLIT = Sodalite::DB::Step[:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }]
  MERGE = Sodalite::DB::Step[:merge_tables, %i[cats dogs], :animals, :species]

  def test_a_decomposition_the_tag_covers_takes_the_object_apart
    memory = animals([1, 'mi', 'cats'], [2, 'pochi', 'dogs'])

    assert_empty memory.preflight_violations(SPLIT)

    memory.carry(SPLIT)

    assert_equal [{ id: 1, name: 'mi' }], memory.rows(:cats)
    assert_equal [{ id: 2, name: 'pochi' }], memory.rows(:dogs)
  end

  # The fibres are a proper part of the object, so there is no coproduct to take
  # apart — and the answer arrives while the object is still whole.
  def test_a_tag_value_outside_the_decomposition_is_refused_with_the_table_untouched
    memory = animals([1, 'mi', 'cats'], [2, 'tweety', 'birds'])
    before = memory.rows(:animals)

    violations = memory.preflight_violations(SPLIT)

    assert_equal 1, violations.size
    assert_equal before, memory.rows(:animals)
  end

  # One value per uncovered fibre, not one per row: what is missing from the
  # decomposition is a fibre, and two birds name it once.
  def test_the_uncovered_fibres_violation_names_the_tag_its_image_and_what_that_breaks
    memory = animals([1, 'tweety', 'birds'], [2, 'nemo', 'fish'], [3, 'iago', 'birds'])

    assert_equal ['the image of animals.species is not contained in the decomposition, which names ' \
                  'no fibre for ["birds", "fish"]: the fibres do not cover animals, so the coproduct ' \
                  'cannot be taken apart along that tag'],
                 memory.preflight_violations(SPLIT)
  end

  # Past the sample the count is the only new information, so the sentence stops
  # listing and says how many it stopped at.
  def test_a_long_image_outside_the_decomposition_is_sampled_and_counted
    rows = (0..11).map { |index| [index, 'x', format('t%02d', index)] }
    memory = animals(*rows)
    step = Sodalite::DB::Step[:split_table, :animals, :species, { 't00' => :t00 }]

    assert_includes memory.preflight_violations(step).first,
                    'no fibre for ["t01", "t02", "t03", "t04", "t05", ...6 more]:'
  end

  def test_the_coproduct_of_disjoint_injections_tags_each_element_with_the_one_it_came_through
    memory = pets(cats: [[1, 'mi']], dogs: [[2, 'pochi']])

    assert_empty memory.preflight_violations(MERGE)

    memory.carry(MERGE)

    assert_equal [{ id: 1, name: 'mi', species: 'cats' }, { id: 2, name: 'pochi', species: 'dogs' }],
                 memory.rows(:animals)
  end

  def test_a_key_reached_through_two_injections_is_refused_because_the_sum_is_not_disjoint
    memory = pets(cats: [[1, 'mi']], dogs: [[1, 'pochi']])

    assert_equal ['the coproduct of [:cats, :dogs] is not disjoint on id, which repeats at [1]: Σ_F ' \
                  'tags which injection an element came through but does not make the keys disjoint, ' \
                  'so two elements sharing a key are not two elements of the sum'],
                 memory.preflight_violations(MERGE)
  end

  # The tag distinguishes the injections, never the elements inside one, so a key
  # repeated within a single source is the same failure of disjointness.
  def test_a_key_repeated_inside_one_injection_is_the_same_failure
    memory = pets(cats: [[1, 'mi'], [1, 'mii']], dogs: [])

    assert_includes memory.preflight_violations(MERGE).first, 'is not disjoint on id, which repeats at [1]:'
  end

  # Every other step is a map that exists for every instance, so there is nothing
  # to refuse. The list is checked against `STEP_KINDS` so "every other" stays
  # true when a kind is added.
  def test_every_other_step_kind_has_nothing_to_refuse
    memory = pets(cats: [[1, 'mi']], dogs: [[2, 'pochi']])
    steps = [Sodalite::DB::Step[:create_table, :birds, { id: :integer }],
             Sodalite::DB::Step[:drop_table, :cats],
             Sodalite::DB::Step[:rename_table, :cats, :felines],
             Sodalite::DB::Step[:add_attribute, :cats, :age, :integer, 0],
             Sodalite::DB::Step[:drop_attribute, :cats, :name],
             Sodalite::DB::Step[:rename_attribute, :cats, :name, :called]]

    assert_equal Sodalite::DB::STEP_KINDS.sort, (steps.map(&:kind) + %i[split_table merge_tables]).sort
    steps.each { |step| assert_empty memory.preflight_violations(step) }
  end

  private

  def animals(*rows)
    memory = Sodalite::DB.memory(ANIMALS)
    rows.each { |id, name, species| memory.insert(:animals, { id: id, name: name, species: species }) }
    memory
  end

  def pets(cats:, dogs:)
    memory = Sodalite::DB.memory(PETS)
    { cats: cats, dogs: dogs }.each do |table, rows|
      rows.each { |id, name| memory.insert(table, { id: id, name: name }) }
    end
    memory
  end
end
