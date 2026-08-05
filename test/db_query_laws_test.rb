# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# The laws a query has to obey, checked where they are cheapest to check: when
# the arrow is built, not on the one request that happens to exercise it.
#
# Each of these was a query that ran. Some of them made the models disagree; the
# worse ones made all three agree on an answer nobody asked for, which is exactly
# what a conformance suite cannot see.
LAWS_SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string, nickname: :string? },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) },
  comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) }
)

# An order is completed by the carrier's key, so an image that has already
# dropped that key cannot carry one. `SELECT DISTINCT name ... ORDER BY name, id`
# is rejected by Postgres and by SQLite alike, while the memory model compares
# two nothings, finds them equal, and passes.
class DBOrderTotalityTest < Minitest::Test
  def test_an_order_over_a_projection_that_dropped_the_tiebreaker_is_refused
    error = assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:users].select(:name).order(:name) }

    assert_match(/cannot be made total/, error.message)
    assert_match(/users\.id/, error.message)
  end

  # The repair belongs to the caller, because the alternative is answering a
  # different question: keep the key, and the order is total again.
  def test_an_order_over_a_projection_that_keeps_the_tiebreaker_still_works
    applied = LAWS_SCHEMA[:users].select(:name, :id).order(:name).total_ordering

    assert_equal %i[name id], applied.map(&:field)
  end

  def test_the_projection_is_not_widened_behind_the_callers_back
    ordered = LAWS_SCHEMA[:users].select(:name, :id).order(:name)

    assert_equal %i[name id], ordered.output_fields
  end

  # A fold's tiebreaker is its grouping keys, and those are in its output by
  # construction, so nothing here reaches phase two.
  def test_a_grouped_order_is_completed_as_before
    applied = LAWS_SCHEMA[:users].group(:city).count(:people).order(:people, :desc).total_ordering

    assert_equal %i[people city], applied.map(&:field)
  end
end

# Deleting through an arrow means naming rows of the carrier, so the arrow has to
# be a subobject of them. Everything that leaves that world is refused here
# rather than in three models that would each leave a different set behind.
class DBDeletableTest < Minitest::Test
  def refused(query, **options)
    assert_raises(Sodalite::DB::QueryError) { query.deletable!(**options) }
  end

  def test_a_subobject_of_the_carrier_is_deletable
    query = LAWS_SCHEMA[:users].where(:city, 'tokyo')

    assert_same query, query.deletable!
  end

  # A projected row is not a row of the carrier, so each model would delete a
  # different set — and for a projection, usually the empty one.
  def test_an_image_is_not_a_set_of_rows
    assert_match(/select is not one/, refused(LAWS_SCHEMA[:users].select(:name)).message)
  end

  def test_a_fold_is_not_a_set_of_rows
    assert_match(/group is not one/, refused(LAWS_SCHEMA[:users].group(:city).count(:people)).message)
  end

  def test_a_coproduct_is_not_a_set_of_rows
    united = LAWS_SCHEMA[:users].where(:id, 1).union(LAWS_SCHEMA[:users].where(:id, 2))

    assert_match(/union is not one/, refused(united).message)
  end

  # A presentation chooses which rows come back, and a deletion that depends on
  # that choice is not a subobject of anything.
  def test_a_window_is_not_a_subobject
    assert_match(/order is not one/, refused(LAWS_SCHEMA[:users].order(:name)).message)
    refused(LAWS_SCHEMA[:users].order(:name).limit(1))
  end

  # `limit` cannot be reached without an order, but the field can still hold one,
  # and the rule is about the window rather than about the road to it.
  def test_a_window_is_refused_by_its_own_field
    assert_match(/limit is not one/, refused(LAWS_SCHEMA[:users].with(limit_rows: 1)).message)
    assert_match(/offset is not one/, refused(LAWS_SCHEMA[:users].with(offset_rows: 1)).message)
  end

  # Composition moved the carrier, so this removes users and not posts. It is
  # allowed, because it is meaningful — but only once the caller has said it.
  def test_deleting_through_a_composition_needs_the_carrier_named
    composed = LAWS_SCHEMA[:posts].follow(:author)
    message = refused(composed).message

    assert_match(/would remove rows of users/, message)
    assert_match(/confirm_carrier: :users/, message)
    assert_same composed, composed.deletable!(confirm_carrier: :users)
  end

  def test_naming_the_object_the_arrow_left_is_still_refused
    refused(LAWS_SCHEMA[:posts].follow(:author), confirm_carrier: :posts)
  end
end

# The fold partitions the carrier into the fibres of the grouping map, so what it
# folds over has to be the relation and its output has to be a row.
class DBFoldTest < Minitest::Test
  # The fragment already closed against `select` after `group`. This is the other
  # direction, and it is the dangerous one: the image holds one row per city
  # already, so every count answers 1 — in all three models at once.
  def test_a_fold_cannot_run_on_an_image
    error = assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:users].select(:city).group(:city) }

    assert_match(/cannot follow select/, error.message)
  end

  def test_a_fold_over_a_subobject_or_a_composition_is_untouched
    assert_equal %i[city people], LAWS_SCHEMA[:users].where(:city, 'tokyo').group(:city).count(:people).output_fields
    assert_equal %i[city people], LAWS_SCHEMA[:posts].follow(:author).group(:city).count(:people).output_fields
  end

  # A name holds one value. `group(:city).count(:city)` asks the fold to put two
  # there: the memory model merges the count over the key, and the SQL model
  # emits two columns under one name.
  def test_a_fold_may_not_take_the_name_of_a_grouping_key
    error = assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:users].group(:city).count(:city) }

    assert_match(/is a grouping key/, error.message)
  end

  def test_a_fold_may_not_take_the_name_of_another_fold
    grouped = LAWS_SCHEMA[:users].group(:city).count(:people)

    assert_match(/already a fold/, assert_raises(Sodalite::DB::QueryError) { grouped.sum(:id, as: :people) }.message)
    assert_raises(Sodalite::DB::QueryError) { grouped.max(:id, as: :city) }
  end

  def test_folds_under_names_of_their_own_still_stack
    folded = LAWS_SCHEMA[:users].group(:city).count(:people).min(:id, as: :oldest)

    assert_equal %i[city people oldest], folded.output_fields
  end
end

# The pullback. `follow` is composition, so it answers with the codomain — ask it
# for "posts whose author lives in tokyo" and it hands back users. `f*(S)` is the
# subobject of *posts* whose image lands in S, and the carrier stays put.
class DBPullbackTest < Minitest::Test
  def test_a_pullback_does_not_move_the_carrier
    pulled = LAWS_SCHEMA[:posts].where_at(:author, :city, 'tokyo')

    assert_equal :posts, pulled.carrier
    assert_equal LAWS_SCHEMA.table(:posts).fields, pulled.output_fields
  end

  def test_a_pullback_appends_the_path_the_operand_and_the_operator
    assert_equal [[:pullback, %i[author], :city, 'tokyo', :eq]],
                 LAWS_SCHEMA[:posts].where_at(:author, :city, 'tokyo').steps
    assert_equal [[:pullback, %i[author], :id, 2, :gte]],
                 LAWS_SCHEMA[:posts].where_at(:author, :id, :gte, 2).steps
  end

  def test_the_path_it_appends_is_frozen
    assert_predicate LAWS_SCHEMA[:posts].where_at(:author, :city, 'tokyo').steps.first[1], :frozen?
  end

  # Two spellings of one operation, so the singular one is the plural one.
  def test_where_at_is_where_along_one_morphism
    assert_equal LAWS_SCHEMA[:posts].where_along(%i[author], :city, 'tokyo'),
                 LAWS_SCHEMA[:posts].where_at(:author, :city, 'tokyo')
  end

  def test_a_path_of_morphisms_composes
    pulled = LAWS_SCHEMA[:comments].where_along(%i[post author], :city, 'tokyo')

    assert_equal :comments, pulled.carrier
    assert_equal [[:pullback, %i[post author], :city, 'tokyo', :eq]], pulled.steps
  end

  # Each name has to be a morphism out of the object reached so far, or the path
  # is not a path in the schema category at all.
  def test_a_name_that_is_not_a_morphism_is_a_build_error
    error = assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:posts].where_at(:editor, :city, 'tokyo') }

    assert_match(/posts has no morphism :editor/, error.message)
    later = assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:comments].where_along(%i[post editor], :city, 'x') }

    assert_match(/posts has no morphism :editor/, later.message)
  end

  def test_a_pullback_along_nothing_is_not_a_pullback
    assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:posts].where_along([], :city, 'tokyo') }
  end

  # The field belongs to the object at the end of the path. The carrier has a
  # `title` and no `city`; the object pulled back from has it the other way.
  def test_the_field_is_judged_at_the_end_of_the_path
    error = assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:posts].where_at(:author, :title, 'hi') }

    assert_match(/users has no field :title/, error.message)
  end

  # And so does the comparison: nil, the complement over `A + 1`, and an order on
  # a type that carries none are refused there for the reasons they are refused
  # on the carrier.
  def test_the_comparison_is_judged_at_the_end_of_the_path
    assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:posts].where_at(:author, :city, nil) }
    assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:posts].where_at(:author, :nickname, :not, 'mi') }
    assert_raises(Sodalite::DB::QueryError) { LAWS_SCHEMA[:posts].where_at(:author, :city, :nonsense, 'x') }
  end

  # It is `where` formed along a path, so it lives and dies with phase one: the
  # fold closes it, and the coproduct leaves the schema's objects behind.
  def test_a_pullback_is_in_the_fragment_and_closes_with_it
    grouped = LAWS_SCHEMA[:posts].group(:title).count(:people)
    united = LAWS_SCHEMA[:posts].where(:id, 1).union(LAWS_SCHEMA[:posts].where(:id, 2))

    assert_raises(Sodalite::DB::QueryError) { grouped.where_at(:author, :city, 'tokyo') }
    assert_raises(Sodalite::DB::QueryError) { united.where_at(:author, :city, 'tokyo') }
  end
end

# `SELECT DISTINCT` is image factorization spelled in SQL, and it is a sort. When
# it is redundant is a property of the arrow, so it is answered once here rather
# than three times, differently, in three models.
class DBDistinctTest < Minitest::Test
  # Nothing composed, and the key is in the output: the tuples are distinct by
  # that key's own uniqueness and the dedupe would sort for nothing.
  def test_a_row_source_that_keeps_the_key_needs_no_dedupe
    refute_predicate LAWS_SCHEMA[:users], :distinct?
    refute_predicate LAWS_SCHEMA[:users].where(:city, 'tokyo'), :distinct?
    refute_predicate LAWS_SCHEMA[:users].select(:id, :name), :distinct?
  end

  # An image that dropped the key can collapse rows, which is what taking it was
  # for.
  def test_an_image_without_the_key_needs_the_dedupe
    assert_predicate LAWS_SCHEMA[:users].select(:name), :distinct?
  end

  # `follow` moves the carrier to the codomain, whose fibres can hold more than
  # one element, so the join repeats a target row once per element over it.
  def test_a_composition_needs_the_dedupe
    assert_predicate LAWS_SCHEMA[:posts].follow(:author), :distinct?
    assert_predicate LAWS_SCHEMA[:posts].follow(:author).select(:id, :name), :distinct?
  end

  # A pullback join is taken along a function — every element has exactly one
  # image — so it duplicates nothing, however long the path is.
  def test_a_pullback_needs_no_dedupe
    refute_predicate LAWS_SCHEMA[:posts].where_at(:author, :city, 'tokyo'), :distinct?
    refute_predicate LAWS_SCHEMA[:comments].where_along(%i[post author], :city, 'tokyo'), :distinct?
  end

  # A fold outputs its keys and its folds, which do not carry the carrier's key,
  # so the image underneath it still has to be taken.
  def test_a_fold_needs_the_dedupe
    assert_predicate LAWS_SCHEMA[:users].group(:city).count(:people), :distinct?
  end
end
