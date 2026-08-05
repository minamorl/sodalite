# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# The in-memory model computes the composites, subobjects, and images rather than
# describing them, so it is where an operation's meaning is pinned before the two
# compiling models are held to it.
#
# A path of two morphisms, `comments -> posts -> users`, because a pullback along
# one hop and a pullback along a path are the same operation and the second is
# where an evaluation that walks per row per hop shows up.
MEMORY_SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string },
  posts: { id: :integer, title: :string, score: :integer?, author: Sodalite::DB.fk(:users) },
  comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) }
)

# Two morphisms have no value here, on purpose: `posts.author=99` and
# `comments.post=77`. An instance that is not a functor is exactly the instance
# a diagnostic is for, and it is also what a pullback has to answer over.
MEMORY_SEED = {
  users: [
    { id: 1, name: 'mina', city: 'tokyo' },
    { id: 2, name: 'rin', city: 'osaka' },
    { id: 3, name: 'ghost', city: 'tokyo' }
  ],
  posts: [
    { id: 10, title: 'hello', score: 3, author: 1 },
    { id: 11, title: 'again', score: nil, author: 1 },
    { id: 12, title: 'daily', score: 5, author: 2 },
    { id: 13, title: 'orphan', score: nil, author: 99 }
  ],
  comments: [
    { id: 100, body: 'nice', post: 10 },
    { id: 101, body: 'meh', post: 12 },
    { id: 102, body: 'ghosted', post: 77 },
    { id: 103, body: 'orphaned', post: 13 }
  ]
}.freeze

# `f*(S)` is a subobject of the domain of f. Which side of the span the answer is
# read from is the whole difference between this and a composition.
class DBMemoryPullbackTest < Minitest::Test
  def setup
    @model = Sodalite::DB.memory(MEMORY_SCHEMA, MEMORY_SEED)
  end

  def titles(query)
    @model.select(query).map { |row| row[:title] }.sort
  end

  # The answer is posts, and whole rows of posts — which is the reason the
  # operation exists, since the composition would hand back users instead.
  def test_a_pullback_keeps_the_carrier
    query = MEMORY_SCHEMA[:posts].where_at(:author, :city, 'tokyo')

    assert_equal :posts, query.carrier
    assert_equal %w[again hello], titles(query)
    assert_equal [%i[id title score author]], @model.select(query).map(&:keys).uniq
  end

  # The other side of the same span: same predicate, different object, and one
  # user who lives in tokyo but is in no fibre at all drops out of it.
  def test_the_composition_answers_over_the_codomain_instead
    followed = MEMORY_SCHEMA[:posts].follow(:author).where(:city, 'tokyo')

    assert_equal :users, followed.carrier
    assert_equal(%w[mina], @model.select(followed).map { |row| row[:name] })
  end

  def test_a_pullback_composes_along_a_path
    query = MEMORY_SCHEMA[:comments].where_along(%i[post author], :city, 'tokyo')

    assert_equal :comments, query.carrier
    assert_equal(%w[nice], @model.select(query).map { |row| row[:body] })
  end

  # A row whose foreign key dangles has no image, so it satisfies nothing — not
  # even a predicate every element of the codomain satisfies. It is the same fact
  # `violations` reports, and it is why an inner join agrees.
  def test_a_row_with_no_image_satisfies_nothing
    everyone = MEMORY_SCHEMA[:posts].where_at(:author, :id, :gte, 1)

    assert_equal %w[again daily hello], titles(everyone)
    assert_includes @model.violations, MEMORY_SCHEMA.dangling_message(:posts, :author, 99, :users)
  end

  # Along a path there are two ways to have no image, and neither is a value.
  def test_a_path_that_breaks_at_either_hop_drops_the_row
    everyone = MEMORY_SCHEMA[:comments].where_along(%i[post author], :id, :gte, 1)

    assert_equal %w[meh nice], @model.select(everyone).map { |row| row[:body] }.sort
  end

  # A pullback is a subobject of the carrier, so it meets the ones taken on the
  # carrier directly — and two subobjects intersect in either order.
  def test_a_pullback_composes_with_a_subobject_and_an_image
    query = MEMORY_SCHEMA[:posts].where_at(:author, :city, 'tokyo').where(:score, :gte, 3).select(:title)
    commuted = MEMORY_SCHEMA[:posts].where(:score, :gte, 3).where_at(:author, :city, 'tokyo').select(:title)

    assert_equal [{ title: 'hello' }], @model.select(query).rows
    assert_equal @model.select(query), @model.select(commuted)
  end
end

# Deleting through an arrow names rows of the carrier, so the arrow has to be a
# subobject of them — and the model that would answer 0 rather than refuse is
# this one, because a tuple is equal to no row.
class DBMemoryDeleteTest < Minitest::Test
  def setup
    @model = Sodalite::DB.memory(MEMORY_SCHEMA, MEMORY_SEED)
  end

  def refused(query, **options)
    error = assert_raises(Sodalite::DB::QueryError) { @model.delete(query, **options) }

    assert_equal MEMORY_SEED[:posts].size, @model.rows(:posts).size
    assert_equal MEMORY_SEED[:users].size, @model.rows(:users).size
    error
  end

  def test_delete_refuses_an_arrow_that_is_not_a_set_of_rows
    united = MEMORY_SCHEMA[:posts].where(:id, 10).union(MEMORY_SCHEMA[:posts].where(:id, 11))

    assert_match(/select is not one/, refused(MEMORY_SCHEMA[:posts].select(:title)).message)
    assert_match(/group is not one/, refused(MEMORY_SCHEMA[:posts].group(:title).count(:written)).message)
    assert_match(/union is not one/, refused(united).message)
    assert_match(/order is not one/, refused(MEMORY_SCHEMA[:posts].order(:title)).message)
  end

  # Composition moved the carrier, so this removes users and not posts. It is
  # meaningful, so it is allowed — but only once the caller has said so.
  def test_deleting_through_a_composition_needs_the_carrier_named
    followed = MEMORY_SCHEMA[:posts].follow(:author)

    assert_match(/would remove rows of users/, refused(followed).message)
    assert_equal 2, @model.delete(followed, confirm_carrier: :users)
    assert_equal(%w[ghost], @model.rows(:users).map { |row| row[:name] })
  end

  # The count is what left the store, not what the arrow named, and a subobject
  # that names nothing is honestly zero rather than accidentally zero.
  def test_delete_answers_with_what_actually_went
    assert_equal 2, @model.delete(MEMORY_SCHEMA[:posts].where_at(:author, :city, 'tokyo'))
    assert_equal %w[daily orphan], @model.rows(:posts).map { |row| row[:title] }.sort
    assert_equal 0, @model.delete(MEMORY_SCHEMA[:posts].where(:title, 'hello'))
    assert_equal 2, @model.delete(MEMORY_SCHEMA[:posts])
    assert_empty @model.rows(:posts)
  end
end

# Reading a nullable column is the partial map `A + 1 ⇀ A`, and the fold takes it
# as one: the `nothing`s never reach a monoid that has no answer for them.
class DBMemoryFoldTest < Minitest::Test
  def folded
    query = MEMORY_SCHEMA[:posts].group(:author).count(:written).sum(:score, as: :total)
                                 .min(:score, as: :lowest).max(:score, as: :highest)
    Sodalite::DB.memory(MEMORY_SCHEMA, MEMORY_SEED).select(query).rows.to_h { |row| [row[:author], row] }
  end

  # `count` folds the elements of the fibre and not a column, so a row whose
  # score is nothing is still an element of it.
  def test_a_nothing_in_the_fibre_is_dropped_before_the_monoid_sees_it
    assert_equal({ author: 1, written: 2, total: 3, lowest: 3, highest: 3 }, folded[1])
    assert_equal({ author: 2, written: 1, total: 5, lowest: 5, highest: 5 }, folded[2])
  end

  # A fibre that is all `nothing` folds to the identity — 0 for a sum, and for
  # min and max the `nothing` that was adjoined to A to be one.
  def test_a_fibre_of_nothing_folds_to_the_identity
    assert_equal({ author: 99, written: 1, total: 0, lowest: nil, highest: nil }, folded[99])
  end
end

# A presentation is a total order, so it has to say where `nothing` goes — and
# there are two ways to be handed one: a nullable column carries the adjoined
# point outright, and `min`/`max` are monoids on `A + 1` that fold an entirely
# nothing fibre to it.
#
# It goes after every element of A, in both directions. It is not an element
# being ordered, it is the point adjoined to A, so the order on A never reaches
# it and reversing that order cannot move it.
class DBMemoryOrderTest < Minitest::Test
  def setup
    @model = Sodalite::DB.memory(MEMORY_SCHEMA, MEMORY_SEED)
  end

  def titles(query)
    @model.select(query).map { |row| row[:title] }
  end

  def test_a_nothing_sorts_after_every_score
    assert_equal %w[hello daily again orphan], titles(MEMORY_SCHEMA[:posts].order(:score))
  end

  # The same tail, not the reversed one, which is the sentence the other two
  # models spell as `NULLS LAST` on every ordering they emit.
  def test_a_nothing_sorts_after_every_score_descending_too
    assert_equal %w[daily hello again orphan], titles(MEMORY_SCHEMA[:posts].order(:score, :desc))
  end

  # Which is what keeps a window meaning something: the two highest scores, and
  # not two absences of one.
  def test_a_window_on_a_descending_order_is_a_window_on_the_scores
    assert_equal %w[daily hello], titles(MEMORY_SCHEMA[:posts].order(:score, :desc).limit(2))
  end

  # Two nothings tie, and a tie is broken by what makes the order total — the
  # key, ascending, exactly as it is for two equal scores.
  def test_two_nothings_tie_and_the_key_breaks_it
    presented = @model.select(MEMORY_SCHEMA[:posts].order(:score))

    assert_equal [11, 13], presented.map { |row| row[:id] }.last(2)
  end

  # And the identity a fold adjoined is placed by the same rule, because it is
  # the same point.
  def test_a_fibre_that_folded_to_the_adjoined_identity_sorts_last_either_way
    folded = MEMORY_SCHEMA[:posts].group(:author).min(:score, as: :lowest)

    assert_equal([1, 2, 99], @model.select(folded.order(:lowest)).map { |row| row[:author] })
    assert_equal([2, 1, 99], @model.select(folded.order(:lowest, :desc)).map { |row| row[:author] })
  end
end

# An instance is a functor into Set, and this is the one place that claim is
# checkable. It is a diagnostic, so it reports and does not prevent.
class DBMemoryFunctorTest < Minitest::Test
  def test_the_diagnostic_speaks_the_schemas_sentence
    model = Sodalite::DB.memory(MEMORY_SCHEMA, MEMORY_SEED)

    refute_predicate model, :functor?
    assert_equal [MEMORY_SCHEMA.dangling_message(:posts, :author, 99, :users),
                  MEMORY_SCHEMA.dangling_message(:comments, :post, 77, :posts)],
                 model.violations
  end

  # `insert` does not check that the target exists, so a write is free to leave
  # the instance without a functor. That is the decision; this is what says so.
  def test_a_write_may_leave_the_instance_without_a_functor
    model = Sodalite::DB.memory(MEMORY_SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }])

    assert_predicate model, :functor?

    model.insert(:posts, { id: 10, title: 'hello', score: nil, author: 99 })

    assert_equal [MEMORY_SCHEMA.dangling_message(:posts, :author, 99, :users)], model.violations
  end

  # And `delete` does not check that nothing points at the row it removes, so the
  # morphism that pointed at it loses its value where it used to have one.
  def test_removing_a_target_leaves_the_morphisms_that_pointed_at_it
    model = Sodalite::DB.memory(MEMORY_SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }],
                                               posts: [{ id: 10, title: 'hello', score: 1, author: 1 }])

    assert_equal 1, model.delete(MEMORY_SCHEMA[:users].where(:id, 1))
    assert_equal [MEMORY_SCHEMA.dangling_message(:posts, :author, 1, :users)], model.violations
  end
end
