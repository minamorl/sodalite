# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
)

# An instance is a functor `C -> Set`. A dangling foreign key is not a bad row;
# it is the morphism having no value at that element.
class DBFunctorTest < Minitest::Test
  def test_a_consistent_instance_is_a_functor
    model = Sodalite::DB.memory(SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }],
                                        posts: [{ id: 10, title: 'hi', author: 1 }])

    assert_predicate model, :functor?
    assert_empty model.violations
  end

  def test_a_dangling_foreign_key_is_a_failure_to_be_a_functor
    model = Sodalite::DB.memory(SCHEMA, users: [], posts: [{ id: 10, title: 'hi', author: 99 }])

    refute_predicate model, :functor?
    assert_equal ['posts.author=99 has no users'], model.violations
  end

  def test_a_row_that_does_not_fit_its_type_never_enters
    model = Sodalite::DB.memory(SCHEMA)

    error = assert_raises(Sodalite::DB::SchemaError) { model.insert(:users, { id: 'one', name: 'x', city: 'y' }) }

    assert_match(%r{/id: expected integer}, error.message)
  end

  def test_a_foreign_key_to_an_unknown_table_is_a_build_error
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(posts: { id: :integer, author: Sodalite::DB.fk(:nobody) })
    end

    assert_match(/points at unknown table :nobody/, error.message)
  end
end

# The carrier moves with composition, so what may be filtered afterwards moves
# too — and that is checked when the arrow is built, not when it is run.
class DBQueryBuildTest < Minitest::Test
  NULLABLE_SCHEMA = Sodalite::DB.schema(
    items: { id: :integer, score: :integer?, tag: :string }
  )

  def test_a_field_that_is_not_on_the_current_carrier_is_a_build_error
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:posts].where(:city, 'tokyo') }
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:posts].follow(:author).where(:title, 'hi') }
  end

  def test_composition_moves_the_carrier
    assert_equal :posts, SCHEMA[:posts].carrier
    assert_equal :users, SCHEMA[:posts].follow(:author).carrier
  end

  def test_a_morphism_that_does_not_exist_is_a_build_error
    assert_raises(Sodalite::DB::SchemaError) { SCHEMA[:posts].follow(:editor) }
  end

  # `NULL` is not `Maybe` and not a subobject — it is three-valued logic, where
  # `NULL = NULL` is unknown. Comparing to it silently is refused rather than
  # quietly given SQL's answer.
  def test_comparing_a_subobject_to_nil_is_refused
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].where(:city, nil) }
  end

  # A window without an order is not a function of the set — it is whatever the
  # storage engine felt like. Paginating on one is how rows repeat and vanish
  # between pages, so it is a build error rather than a production surprise.
  def test_a_window_without_an_order_is_a_build_error
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].limit(10) }
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].offset(10) }
    SCHEMA[:users].order(:name).limit(10) # no raise
  end

  # An order that is not total is not a function of the set either, so the
  # identifying fields are appended and the applied order is always total.
  def test_an_order_is_completed_to_a_total_one
    applied = SCHEMA[:users].order(:city).total_ordering

    assert_equal %i[city id], applied.map(&:field)
    assert_equal %i[asc asc], applied.map(&:direction)
  end

  def test_a_grouped_order_is_completed_by_its_grouping_keys
    applied = SCHEMA[:users].group(:city).count(:people).order(:people, :desc).total_ordering

    assert_equal %i[people city], applied.map(&:field)
  end

  # The fold consumes the relation, so the regular fragment closes when it
  # starts. A subobject of a grouped relation is HAVING — a different operation,
  # not offered rather than quietly conflated with WHERE.
  def test_the_fragment_closes_where_the_fold_begins
    grouped = SCHEMA[:users].group(:city).count(:people)

    assert_raises(Sodalite::DB::QueryError) { grouped.where(:city, 'tokyo') }
    assert_raises(Sodalite::DB::QueryError) { grouped.follow(:author) }
    assert_raises(Sodalite::DB::QueryError) { grouped.select(:city) }
  end

  def test_an_aggregate_needs_a_group_to_fold_over
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].count(:people) }
  end

  def test_a_nullable_fold_needs_explicit_elimination
    error = assert_raises(Sodalite::DB::QueryError) do
      NULLABLE_SCHEMA[:items].group(:tag).sum(:score, as: :total)
    end

    assert_match(/where_present/, error.message)
  end

  def test_count_counts_elements_so_it_does_not_eliminate_a_nullable_value
    query = NULLABLE_SCHEMA[:items].group(:score).count(:items)

    assert_equal :count, query.aggregates.first.kind
  end

  def test_ordering_a_nullable_field_needs_explicit_elimination
    error = assert_raises(Sodalite::DB::QueryError) { NULLABLE_SCHEMA[:items].order(:score) }

    assert_match(/where_present/, error.message)
    NULLABLE_SCHEMA[:items].where_present(:score).order(:score)
  end

  def test_a_nullable_group_key_cannot_be_an_implicit_ordering_tiebreak
    error = assert_raises(Sodalite::DB::QueryError) do
      NULLABLE_SCHEMA[:items].group(:score).count(:items).order(:items)
    end

    assert_match(/where_present/, error.message)
  end

  def test_ordering_by_something_that_is_not_in_the_result_is_a_build_error
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].select(:name).order(:city) }
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].group(:city).count(:people).order(:name) }
  end

  # `avg` is absent because it is not a monoid: averages do not combine
  # associatively. The pair that is monoidal stays available.
  def test_the_aggregates_offered_are_exactly_the_monoids
    assert_equal %i[count sum min max], Sodalite::DB::MONOIDS.keys
    refute_respond_to SCHEMA[:users].group(:city), :avg
  end

  def test_a_projected_relation_has_no_row_type
    relation = Sodalite::DB.memory(SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }])
                           .select(SCHEMA[:users].select(:name))

    assert_raises(Sodalite::DB::QueryError) { relation.typed }
  end

  def test_update_refuses_identity_morphisms_and_composition
    model = Sodalite::DB.memory(SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }],
                                        posts: [{ id: 10, title: 'hi', author: 1 }])

    assert_raises(Sodalite::DB::QueryError) { model.update(SCHEMA[:users], id: 2) }
    assert_raises(Sodalite::DB::QueryError) { model.update(SCHEMA[:posts], author: 1) }
    assert_raises(Sodalite::DB::QueryError) do
      model.update(SCHEMA[:posts].follow(:author), name: 'renamed')
    end
  end
end

# A transaction is a combinator handler, and rollback is what `Err` means to it.
# The caller never asks for one.
class DBTransactionTest < Minitest::Test
  include Sodalite::TestSupport

  def model_with_one_user
    Sodalite::DB.memory(SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }])
  end

  def write_two_posts(fail_on_second:)
    first = Berylx::Task[:first] do |lay, io|
      io.perform(Sodalite::DB::INSERT, [:posts, { id: 10, title: 'kept', author: 1 }])
      lay
    end
    second = Berylx::Task[:second] do |lay, io|
      io.perform(Sodalite::DB::INSERT, [:posts, { id: 11, title: 'doomed', author: 1 }])
      fail_on_second ? lay.reject(:conflict, 'no') : lay
    end
    Sodalite::DB.atomically(:write, first >> second)
  end

  def test_a_successful_scope_commits_everything_in_it
    model = model_with_one_user
    result = Berylx::Root[].call(write_two_posts(fail_on_second: false),
                                 handlers: Sodalite::DB.handlers(model))

    assert_instance_of Berylx::Ok, result
    assert_equal(%w[kept doomed], model.rows(:posts).map { |row| row[:title] })
  end

  # The first insert already happened when the second step failed. Nobody asked
  # for a rollback; the scope saw `Err` and that is what `Err` means to it.
  def test_a_failing_scope_rolls_back_the_writes_that_already_happened
    model = model_with_one_user
    result = Berylx::Root[].call(write_two_posts(fail_on_second: true),
                                 handlers: Sodalite::DB.handlers(model))

    assert_instance_of Berylx::Err, result
    assert_empty model.rows(:posts)
  end

  # berylx kept the state and the name of the step that failed, so the rollback
  # arrives with a saga's compensation data already attached.
  def test_the_rolled_back_failure_still_says_which_task_failed
    result = Berylx::Root[].call(write_two_posts(fail_on_second: true),
                                 handlers: Sodalite::DB.handlers(model_with_one_user))

    assert_equal :conflict, result.code
    assert_equal :second, result.failed_node
  end
end

# The payoff at the framework boundary: a route whose handler map is a model.
class DBRouteTest < Minitest::Test
  include Sodalite::TestSupport

  BY_CITY = Berylx::Task[:by_city] do |lay, io|
    found = io.perform(Sodalite::DB::SELECT,
                       SCHEMA[:users].where(:city, lay[:request].get.params.city).select(:name))
    lay[:response].set(Sodalite.ok({ names: found.map { |row| row[:name] }.sort }))
  end

  RENAME = Berylx::Task[:rename] do |lay, io|
    count = io.perform(Sodalite::DB::UPDATE,
                       [SCHEMA[:users].where(:id, lay[:request].get.params.id), { name: lay[:request].get.body.name }])
    lay[:response].set(Sodalite.ok({ updated: count }))
  end

  def route
    Sodalite::Route[:get, '/cities/:city/users',
                    params: { city: :string },
                    responses: { 200 => { names: [:string] } },
                    run: BY_CITY]
  end

  def seeded
    Sodalite::DB.memory(SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' },
                                        { id: 2, name: 'rin', city: 'osaka' },
                                        { id: 3, name: 'ghost', city: 'tokyo' }])
  end

  def test_a_route_reaches_its_data_through_the_relational_signature
    app = Sodalite::App.new(routes: [route], handlers: Sodalite::DB.handlers(seeded))

    triple = app.call(env(:get, '/cities/tokyo/users'))

    assert_equal 200, triple[0]
    assert_equal({ 'names' => %w[ghost mina] }, json_body(triple))
  end

  # `find_user` was never an effect. It was an arrow, and arrows are values you
  # build once and reuse.
  def test_a_named_query_is_a_value_not_a_verb
    in_tokyo = SCHEMA[:users].where(:city, 'tokyo')

    assert_equal 2, seeded.select(in_tokyo).size
    assert_equal 1, seeded.select(in_tokyo.where(:name, 'mina')).size
  end

  def test_a_route_can_perform_update_through_the_relational_signature
    update_route = Sodalite::Route[:patch, '/users/:id',
                                   params: { id: :integer }, body: { name: :string },
                                   responses: { 200 => { updated: :integer } }, run: RENAME]
    model = seeded
    app = Sodalite::App.new(routes: [update_route], handlers: Sodalite::DB.handlers(model))

    triple = app.call(env(:patch, '/users/1', body: JSON.generate(name: 'new')))

    assert_equal({ 'updated' => 1 }, json_body(triple))
    assert_equal 'new', model.select(SCHEMA[:users].where(:id, 1)).rows.first[:name]
  end
end
