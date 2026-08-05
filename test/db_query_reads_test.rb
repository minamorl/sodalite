# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# What an arrow reads, as a set of places.
#
# The property behind every test here is soundness: if a write's addresses are
# disjoint from a query's `reads`, that write cannot change that query's answer.
# Only one half of it is built yet, so these tests are about `reads` alone —
# given an arrow, exactly which addresses come back.
#
# Each expectation is written out in full rather than checked for membership,
# because the failures worth catching are the ones that report *fewer* places
# than the answer really depends on. A missing address is a stale answer served
# as fresh, and no assertion that only looks for what should be there can see it.
READS_SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string, nickname: :string? },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) },
  comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) },
  accounts: { id: :string, plan: :string },
  sessions: { id: :integer, agent: :string, account: Sodalite::DB.fk(:accounts) }
)

# A set of addresses read as text, in the one order `Address` sorts into, so a
# failure reads as a set of places rather than as a wall of object ids.
module ReadPlaces
  def places(query)
    query.reads.map(&:to_s).sort
  end
end

# Phase one: the walk, and which object each step is spoken against.
class DBQueryReadsWalkTest < Minitest::Test
  include ReadPlaces

  # The root contributes its elements, and with no projection the answer is
  # whole rows, so every map out of it is consulted too.
  def test_the_bare_root_reads_its_elements_and_every_field
    assert_equal ['users', 'users.city', 'users.id', 'users.name', 'users.nickname'],
                 places(READS_SCHEMA[:users])
  end

  # A subobject consults the map it compares, and an image consults the maps it
  # keeps. The projection is what makes this discriminating: without it the whole
  # row would swallow both.
  def test_a_subobject_and_an_image_read_the_fields_they_name
    query = READS_SCHEMA[:users].where(:city, 'tokyo').select(:name, :id)

    assert_equal ['users', 'users.city', 'users.id', 'users.name'], places(query)
  end

  # Eliminating the `+ 1` is still consulting the map, and both directions of it
  # consult the same one.
  def test_a_null_filter_reads_the_field_it_eliminates
    absent = READS_SCHEMA[:users].select(:id, :nickname).where_null(:nickname)
    present = READS_SCHEMA[:users].select(:id, :nickname).where_present(:nickname)

    assert_equal ['users', 'users.id', 'users.nickname'], places(absent)
    assert_equal places(absent), places(present)
  end

  # Composition consults the morphism it moves along, and lands on an object
  # whose elements the answer now depends on. `posts.title` is not read: the
  # answer is rows of users.
  def test_a_composition_reads_the_morphism_and_the_object_it_lands_on
    assert_equal ['posts', 'posts.author', 'users', 'users.city', 'users.id', 'users.name', 'users.nickname'],
                 places(READS_SCHEMA[:posts].follow(:author))
  end

  # The carrier moved, so everything after the hop is spoken against users. A
  # walk that left the carrier at posts would report `posts.city` — a map that
  # does not exist — and would say nothing about users at all.
  def test_a_step_after_a_composition_is_read_against_the_object_it_moved_to
    query = READS_SCHEMA[:posts].follow(:author).where(:city, 'tokyo').select(:name, :id)

    assert_equal ['posts', 'posts.author', 'users', 'users.city', 'users.id', 'users.name'], places(query)
  end
end

# The pullback. It emits the join a composition emits and does not move the
# carrier, and the comparison is made at the far end of the path.
class DBQueryReadsPullbackTest < Minitest::Test
  include ReadPlaces

  # The carrier stays at posts — so the whole row read is posts' — and the
  # comparison is `users.city`, not `posts.city`.
  def test_a_pullback_reads_the_morphism_here_and_the_comparison_there
    assert_equal ['posts', 'posts.author', 'posts.id', 'posts.title', 'users', 'users.city'],
                 places(READS_SCHEMA[:posts].where_at(:author, :city, 'tokyo'))
  end

  # The step that follows it is still spoken against posts. A walk that let the
  # pullback move the carrier would attribute this `where` to users.
  def test_a_step_after_a_pullback_is_still_read_against_the_carrier
    query = READS_SCHEMA[:posts].where_at(:author, :city, 'tokyo').where(:title, 'hi').select(:title)

    assert_equal ['posts', 'posts.author', 'posts.title', 'users', 'users.city'], places(query)
  end

  # Every hop consults the morphism it is named by, on the object standing at
  # that hop, and every object the path passes through contributes its elements.
  # `posts` is here only because the path went through it.
  def test_a_two_hop_path_reads_every_hop_and_every_object_it_passes_through
    query = READS_SCHEMA[:comments].where_along(%i[post author], :city, 'tokyo')

    assert_equal ['comments', 'comments.body', 'comments.id', 'comments.post',
                  'posts', 'posts.author', 'users', 'users.city'], places(query)
  end

  # A string-keyed object is reached the same way, and so is a comparison
  # against the key itself: it belongs to the object at the far end.
  def test_the_far_field_belongs_to_the_far_object_even_when_it_is_the_key
    plan = READS_SCHEMA[:sessions].where_at(:account, :plan, 'pro')
    key = READS_SCHEMA[:sessions].select(:id, :account).where_at(:account, :id, :gt, 'a')

    assert_equal ['accounts', 'accounts.plan', 'sessions', 'sessions.account', 'sessions.agent', 'sessions.id'],
                 places(plan)
    assert_equal ['accounts', 'accounts.id', 'sessions', 'sessions.account', 'sessions.id'], places(key)
  end
end

# The rule most easily missed: an arrow with no projection answers with whole
# rows, so it reads every field of its final carrier.
class DBQueryReadsWholeRowTest < Minitest::Test
  include ReadPlaces

  # `nickname` is named nowhere in this arrow and is read all the same, because
  # the answer carries it. An update to it is not a write this query survives.
  def test_an_unprojected_arrow_reads_the_fields_it_never_named
    assert_includes places(READS_SCHEMA[:users].where(:city, 'tokyo')), 'users.nickname'
  end

  # And an image reads only what it kept, which is the whole reason the rule is
  # worth stating: the two answers really are different.
  def test_an_image_reads_only_the_fields_it_kept
    projected = READS_SCHEMA[:users].select(:id, :name)

    assert_equal ['users', 'users.id', 'users.name'], places(projected)
    refute_includes places(projected), 'users.nickname'
  end

  # The whole row is the *final* carrier's, not the root's.
  def test_the_whole_row_is_read_off_the_object_the_walk_ended_on
    composed = places(READS_SCHEMA[:posts].follow(:author))

    assert_includes composed, 'users.nickname'
    refute_includes composed, 'posts.title'
  end

  # The last projection is the one that decides, and an earlier one is still a
  # map that was consulted to reach it.
  def test_a_reprojection_reads_both_images
    query = READS_SCHEMA[:users].select(:id, :name, :city).select(:id, :city)

    assert_equal ['users', 'users.city', 'users.id', 'users.name'], places(query)
  end
end

# Phases two and three: the fold, and the presentation of its result.
class DBQueryReadsFoldTest < Minitest::Test
  include ReadPlaces

  # A fold cannot follow a projection, so on an arrow that can be built its
  # addresses are already in the whole row underneath it.
  def test_a_fold_over_a_relation_reads_the_row_it_folds
    query = READS_SCHEMA[:users].group(:city).count(:people).sum(:id, as: :total)

    assert_equal ['users', 'users.city', 'users.id', 'users.name', 'users.nickname'], places(query)
  end

  # The rule is the fold's own even so, and this is the arrow that shows it —
  # reached through `with`, because the builder refuses a fold after an image.
  # The grouping map and the folded column are read; `count` folds the elements
  # of the fibre themselves and reads no map at all.
  def test_a_fold_reads_its_grouping_map_and_the_columns_it_folds
    folded = READS_SCHEMA[:users].select(:name).with(
      grouping: %i[city].freeze,
      aggregates: [Sodalite::DB::Aggregate.new(name: :people, kind: :count, field: nil),
                   Sodalite::DB::Aggregate.new(name: :total, kind: :sum, field: :id)].freeze
    )

    assert_equal ['users', 'users.city', 'users.id', 'users.name'], places(folded)
  end

  # A `having` names a fold's output, which is computed here rather than stored,
  # so there is no place in the instance for it to name.
  def test_a_having_reads_nothing
    grouped = READS_SCHEMA[:users].group(:city).count(:people)

    assert_equal places(grouped), places(grouped.having(:people, :gt, 2))
  end

  # An order on a fold's output names the same computed value, so it names no
  # place either — `users.people` is not a map of anything.
  def test_an_order_on_a_folds_output_reads_nothing
    grouped = READS_SCHEMA[:users].group(:city).count(:people)
    ordered = grouped.order(:people, :desc)

    assert_equal places(grouped), places(ordered)
    refute_includes places(ordered), 'users.people'
  end

  # An order on a field of the carrier reads that field — and adds nothing,
  # because it had to be in the output to be ordered by, and the tiebreaker that
  # makes it total had to be there too.
  def test_an_order_on_a_field_adds_nothing_the_output_had_not_read
    projected = READS_SCHEMA[:users].select(:name, :id)
    ordered = projected.order(:name)

    assert_equal ['users', 'users.id', 'users.name'], places(ordered)
    assert_equal places(projected), places(ordered)
    assert_equal %i[name id], ordered.total_ordering.map(&:field)
  end

  # A window chooses how much of an order to hand back and consults no map to do
  # it.
  def test_a_window_reads_nothing
    ordered = READS_SCHEMA[:users].select(:name, :id).order(:name)

    assert_equal places(ordered), places(ordered.limit(5).offset(2))
  end
end

# The coproduct, and what a value this has to be.
class DBQueryReadsCoproductTest < Minitest::Test
  include ReadPlaces

  # Set union, so the answer depends on everything either side depends on. Drop
  # the union's contribution and `users` vanishes from a query whose answer
  # plainly depends on it.
  def test_a_union_reads_both_sides
    left = READS_SCHEMA[:posts].where(:id, 1)
    united = left.union(READS_SCHEMA[:posts].where_at(:author, :city, 'tokyo'))

    assert_equal ['posts', 'posts.author', 'posts.id', 'posts.title', 'users', 'users.city'], places(united)
    refute_equal places(left), places(united)
  end

  # Two places that arrive twice are one place.
  def test_the_same_place_reached_twice_is_one_address
    query = READS_SCHEMA[:posts].where(:title, 'hi').select(:title)

    assert_equal ['posts', 'posts.title'], places(query)
  end

  def test_reads_is_a_frozen_set_of_addresses_and_a_function_of_the_arrow_alone
    query = READS_SCHEMA[:posts].where_at(:author, :city, 'tokyo')

    assert_kind_of Set, query.reads
    assert_predicate query.reads, :frozen?
    assert_equal query.reads, query.reads
    assert(query.reads.all?(Sodalite::DB::Address))
  end

  # A step kind this walk has never heard of reads nothing, and reading nothing
  # is exactly the shape of an unsound answer — so it is refused instead.
  def test_a_step_this_walk_does_not_know_is_refused_rather_than_read_as_empty
    query = READS_SCHEMA[:users].with(steps: [%i[nonsense name]].freeze)
    error = assert_raises(Sodalite::DB::QueryError) { query.reads }

    assert_match(/no reading of step :nonsense/, error.message)
  end
end
