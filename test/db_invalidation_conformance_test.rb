# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  INVALIDATION_SQLITE = true
rescue LoadError
  INVALIDATION_SQLITE = false
end

# The claim the invalidation calculus rests on, measured rather than argued.
#
#   reads(query) disjoint from writes(tag, payload)
#     => performing that operation does not change that query's answer
#
# `Address` says what a place is, `QueryReads` says which of them an arrow
# consults, and `DB.writes` says which of them an operation dirties. Each of
# those is checked on its own next door — `db_address_test.rb`,
# `db_query_reads_test.rb`, `db_writes_test.rb` — and every one of those checks
# is about the *value* that comes back. None of them touches an instance, so
# none of them can tell you whether the sets mean what the design says they mean.
# Until this file, the property was asserted nowhere: it was an argument.
#
# There is one way to check it, and it is to do it. Take an arrow and an
# operation, read the answer, perform the operation, read the answer again, and
# see whether the calculus was right about what just happened. And do it in all
# three models, because "the answer did not change" is a claim about an
# instance, and this repository has three of them: a walk in Set, compiled SQL
# text, and a dataset algebra. A calculus that held in `Memory` and not in
# `Sql` would be a calculus about a Hash of Arrays.
#
# Both directions are driven, and they are not the same kind of statement:
#
#   disjoint => unchanged     is the law. It is what the calculus is for, and a
#                             failure is an unsoundness: a stale answer served
#                             as fresh.
#   not disjoint => changed   is **not** a law. The calculus is deliberately
#                             imprecise — it stops at the column — so a write may
#                             be reported as possibly-stale and change nothing.
#                             It is asserted here only for pairs built so that
#                             the answer really does move, and its whole value is
#                             that it keeps the first direction honest: a
#                             calculus that called every write stale would pass
#                             the law trivially and be worth nothing.
#
# The imprecision itself is pinned as a property rather than left to be
# rediscovered as a surprise — see the false-positive test below.
INVALIDATION_SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string, nickname: :string? },
  posts: { id: :integer, title: :string, views: :integer, author: Sodalite::DB.fk(:users) },
  comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) },
  # An object no arrow in this file reaches and no morphism points at, so that
  # "a write to something else entirely" is a case rather than a figure of
  # speech.
  audits: { id: :integer, note: :string }
)

# `comments -> posts -> users` gives the two-hop path a pullback needs, and
# every fibre below is non-empty on both sides of it, so a pair that expects a
# change has somewhere for the change to show.
INVALIDATION_SEED = {
  users: [
    { id: 1, name: 'mina', city: 'tokyo', nickname: 'mi' },
    { id: 2, name: 'rin', city: 'osaka', nickname: nil },
    { id: 3, name: 'ghost', city: 'tokyo', nickname: nil }
  ],
  posts: [
    { id: 10, title: 'hello', views: 1, author: 1 },
    { id: 11, title: 'again', views: 2, author: 1 },
    { id: 12, title: 'hello', views: 3, author: 2 }
  ],
  comments: [
    { id: 20, body: 'nice', post: 10 },
    { id: 21, body: 'hm', post: 12 }
  ],
  audits: [{ id: 30, note: 'boot' }]
}.freeze

# One (query, operation) pair, together with what the calculus is expected to say
# about it and what the instance is expected to do.
#
# The operation is held as the tag and the payload rather than as a block,
# because that pair is exactly what `DB.writes` reads and exactly what the caller
# was about to hand `io.perform`. Holding a block instead would let the thing
# measured drift from the thing asked about.
InvalidationPair = Data.define(:label, :query, :tag, :payload, :confirm_carrier, :disjoint, :changed) do
  def self.of(label, query, operation, disjoint:, changed:)
    tag, payload, confirm_carrier = operation
    new(label: label, query: query, tag: tag, payload: payload,
        confirm_carrier: confirm_carrier, disjoint: disjoint, changed: changed)
  end

  def reads = query.reads
  def writes = Sodalite::DB.writes(tag, payload)

  # The measured verdict, as against the declared one. Both are asserted, so a
  # pair cannot quietly stop being the case it was written to be.
  def disjoint? = reads.disjoint?(writes)

  def method_name = label.downcase.gsub(/[^a-z0-9]+/, '_')

  # A failure here is about two sets of places, so it prints as two sets of
  # places rather than as a wall of object ids.
  def explain
    "#{label}\n  reads : #{reads.sort.join(', ')}\n  writes: #{writes.sort.join(', ')}"
  end
end

# Three models over one instance, and the one way this file performs anything.
module InvalidationModels
  # Minimal adapter over sqlite3: `execute(sql, binds) -> rows`.
  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end

  def models(schema, seed)
    memory = Sodalite::DB.memory(schema, seed)
    sql = Sodalite::DB.sql(schema, Adapter.new).create_tables_for_test!
    sequel = Sodalite::DB.sequel(schema, Sequel.sqlite).create_tables_for_test!
    seed.each { |table, rows| rows.each { |row| [sql, sequel].each { |model| model.insert(table, row) } } }
    { memory: memory, sql: sql, sequel: sequel }
  end

  # The operation, performed. `confirm_carrier` is passed through because a write
  # through a composition names rows of the codomain and every model makes the
  # caller say so — the same value `DB.writes` reads the carrier off.
  def perform(model, tag, payload, confirm_carrier = nil)
    case tag
    when Sodalite::DB::INSERT then model.insert(payload[0], payload[1])
    when Sodalite::DB::UPDATE then model.update(payload[0], payload[1], confirm_carrier: confirm_carrier)
    when Sodalite::DB::DELETE then model.delete(payload, confirm_carrier: confirm_carrier)
    else raise ArgumentError, "no way to perform #{tag.inspect}"
    end
  end
end

# The table. Held in a module of its own so the two shorthands it is written
# with do not become top-level names in a suite that loads every file into one
# process.
module InvalidationPairs
  S = INVALIDATION_SCHEMA
  DBW = Sodalite::DB

  ALL = [
    # --- the case the whole design exists for ----------------------------------
    # An update to a column the image dropped. A scheme addressed at the object
    # would call this stale; addressed at the column it is not, and the instance
    # agrees.
    InvalidationPair.of(
      'a projection untouched by an update to another column',
      S[:users].select(:id, :name),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'osaka' }]],
      disjoint: true, changed: false
    ),

    # The same shape with a change written as a function of the old value, because
    # `:add` is the change the fifth operation exists for and it must address the
    # same place `:set` does.
    InvalidationPair.of(
      'a projection untouched by an add to a column it dropped',
      S[:posts].select(:id, :title),
      [DBW::UPDATE, [S[:posts].where(:id, 10), { views: DBW.add(5) }]],
      disjoint: true, changed: false
    ),

    # --- an update to a column the query does consult ---------------------------
    InvalidationPair.of(
      'an update to a column the query filters on',
      S[:users].where(:city, 'tokyo').select(:id),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'osaka' }]],
      disjoint: false, changed: true
    ),

    InvalidationPair.of(
      'an update to a column the query only projects',
      S[:users].where(:city, 'tokyo').select(:id, :name),
      [DBW::UPDATE, [S[:users].where(:id, 1), { name: 'MINA' }]],
      disjoint: false, changed: true
    ),

    # The rule most easily missed, measured: an arrow with no projection answers
    # with whole rows, so it reads a column nobody named — and an update to that
    # column really does change the answer.
    InvalidationPair.of(
      'an update to a column an unprojected arrow never named',
      S[:users].where(:city, 'tokyo'),
      [DBW::UPDATE, [S[:users].where(:id, 1), { nickname: 'zz' }]],
      disjoint: false, changed: true
    ),

    # --- an insert changes which elements exist, and nothing else ---------------
    InvalidationPair.of(
      'an insert into another object',
      S[:users].select(:id, :name),
      [DBW::INSERT, [:posts, { id: 13, title: 'fresh', views: 9, author: 1 }]],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'an insert into the object the query reads',
      S[:users].select(:id, :name),
      [DBW::INSERT, [:users, { id: 4, name: 'new', city: 'kyoto', nickname: nil }]],
      disjoint: false, changed: true
    ),

    # --- a delete changes which elements exist ----------------------------------
    InvalidationPair.of(
      'a delete from another object',
      S[:users].select(:id, :name),
      [DBW::DELETE, S[:posts].where(:id, 12)],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'a delete from the object the query reads',
      S[:users].where(:city, 'tokyo').select(:id),
      [DBW::DELETE, S[:users].where(:id, 1)],
      disjoint: false, changed: true
    ),

    # --- an operation on a wholly unrelated object ------------------------------
    InvalidationPair.of(
      'an operation on a wholly unrelated object',
      S[:posts].where_at(:author, :city, 'tokyo').select(:title),
      [DBW::INSERT, [:audits, { id: 31, note: 'unrelated' }]],
      disjoint: true, changed: false
    ),

    # --- a composition, and a write to the codomain -----------------------------
    # The answer is rows of users reached through `posts.author`, so a write to
    # users is a write to the object the answer is made of — and it still misses,
    # because it names a column the projection dropped.
    InvalidationPair.of(
      'a composition, with a write to a column of the codomain it dropped',
      S[:posts].follow(:author).select(:name),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'kyoto' }]],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'a composition, with a write to a column of the codomain it keeps',
      S[:posts].follow(:author).select(:name),
      [DBW::UPDATE, [S[:users].where(:id, 1), { name: 'MINA' }]],
      disjoint: false, changed: true
    ),

    # The answer is made of elements of the codomain, so which elements it has is
    # read as surely as the columns are.
    InvalidationPair.of(
      'a composition, with a delete from the codomain it lands on',
      S[:posts].follow(:author).select(:name),
      [DBW::DELETE, S[:users].where(:id, 1)],
      disjoint: false, changed: true
    ),

    # The write itself taken through a composition: `writes` addresses the
    # *carrier*, which is what `confirm_carrier` made the caller say out loud, so
    # this dirties `users.city` and leaves an arrow over posts alone.
    InvalidationPair.of(
      'a write through a composition, addressed at the codomain it changes',
      S[:posts].select(:id, :title),
      [DBW::UPDATE, [S[:posts].follow(:author), { city: 'nara' }], :users],
      disjoint: true, changed: false
    ),

    # And the same write seen by an arrow over that codomain, which is what makes
    # the pair above a measurement rather than a coincidence: addressed at the
    # root it would name `posts.city`, a map that does not exist, and this reader
    # would be told it was safe while its answer moved.
    InvalidationPair.of(
      'a write through a composition, seen by an arrow over the codomain',
      S[:users].select(:city),
      [DBW::UPDATE, [S[:posts].follow(:author), { city: 'nara' }], :users],
      disjoint: false, changed: true
    ),

    # --- a pullback, and a write to the far object ------------------------------
    # The carrier never moved, so the answer is titles of posts; the far object is
    # consulted only at `users.city`, and a write to `users.name` misses it.
    InvalidationPair.of(
      'a pullback, with a write to a column of the far object it does not compare',
      S[:posts].where_at(:author, :city, 'tokyo').select(:title),
      [DBW::UPDATE, [S[:users].where(:id, 1), { name: 'MINA' }]],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'a pullback, with a write to the column of the far object it compares',
      S[:posts].where_at(:author, :city, 'tokyo').select(:title),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'osaka' }]],
      disjoint: false, changed: true
    ),

    # The step after a pullback is still spoken against the carrier, which never
    # moved. A walk that let the pullback move it would file this projection under
    # `users` and leave `posts.title` unread — a stale answer no test of the
    # emitted SQL could see, because the SQL would still be right.
    InvalidationPair.of(
      'a pullback, with a write to the column the carrier projects',
      S[:posts].where_at(:author, :city, 'tokyo').select(:title),
      [DBW::UPDATE, [S[:posts].where(:id, 10), { title: 'HELLO' }]],
      disjoint: false, changed: true
    ),

    # The join is taken along a function and is inner, so an element the path can
    # no longer land on takes the row that pointed at it out of the answer. That
    # is why every object a path arrives at contributes its *elements* and not
    # only the morphism that reached it.
    InvalidationPair.of(
      'a pullback, with a delete from the object at the far end of its path',
      S[:posts].where_at(:author, :city, 'tokyo').select(:title),
      [DBW::DELETE, S[:users].where(:id, 1)],
      disjoint: false, changed: true
    ),

    # Two hops, so the object standing in the middle is consulted for its morphism
    # and not for its columns.
    InvalidationPair.of(
      'a two-hop pullback, with a write to a column of the object it passes through',
      S[:comments].where_along(%i[post author], :city, 'tokyo').select(:body),
      [DBW::UPDATE, [S[:posts].where(:id, 10), { views: DBW.add(1) }]],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'a two-hop pullback, with a write to the morphism it hops along',
      S[:comments].where_along(%i[post author], :city, 'tokyo').select(:body),
      [DBW::UPDATE, [S[:posts].where(:id, 10), { author: 2 }]],
      disjoint: false, changed: true
    ),

    # And the same for the object standing in the middle: remove the element the
    # first hop lands on and the second hop has nowhere to go, so the row that
    # started the walk leaves the answer.
    InvalidationPair.of(
      'a two-hop pullback, with a delete from the object it hops through',
      S[:comments].where_along(%i[post author], :city, 'tokyo').select(:body),
      [DBW::DELETE, S[:posts].where(:id, 10)],
      disjoint: false, changed: true
    ),

    # --- a grouped query --------------------------------------------------------
    # A fold cannot follow a projection, so a grouped arrow reads the whole row it
    # folds. What is left disjoint is another object entirely.
    InvalidationPair.of(
      'a grouped query, with a write to another object',
      S[:posts].group(:author).count(:many),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'osaka' }]],
      disjoint: true, changed: false
    ),

    # An insert dirties which elements exist, and a fold counts them.
    InvalidationPair.of(
      'a grouped query, with an insert into the object it folds',
      S[:posts].group(:author).count(:many),
      [DBW::INSERT, [:posts, { id: 14, title: 'more', views: 0, author: 2 }]],
      disjoint: false, changed: true
    ),

    # --- an ordered query with a window -----------------------------------------
    # The window is where an order stops being a presentation and starts deciding
    # which rows come back at all, so this is the pair where comparing as a set
    # would have been the wrong comparison.
    InvalidationPair.of(
      'an ordered query with a window, with a write to a column it dropped',
      S[:users].select(:id, :name).order(:name).limit(2),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'osaka' }]],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'an ordered query with a window, with a write to the column it orders by',
      S[:users].select(:id, :name).order(:name).limit(2),
      [DBW::UPDATE, [S[:users].where(:id, 3), { name: 'aaa' }]],
      disjoint: false, changed: true
    ),

    # --- a union ----------------------------------------------------------------
    # Set union, so the answer depends on everything either side depends on and a
    # write has to miss both to miss.
    InvalidationPair.of(
      'a union, with a write to a column neither side consults',
      S[:users].where(:city, 'tokyo').select(:name).union(S[:users].where(:city, 'osaka').select(:name)),
      [DBW::UPDATE, [S[:users].where(:id, 1), { nickname: 'zz' }]],
      disjoint: true, changed: false
    ),

    InvalidationPair.of(
      'a union, with a write to the column both sides filter on',
      S[:users].where(:city, 'tokyo').select(:name).union(S[:users].where(:city, 'osaka').select(:name)),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'kyoto' }]],
      disjoint: false, changed: true
    ),

    # The side that reaches furthest is the one that decides. Only the right
    # branch here consults `users` at all, so a union that contributed nothing but
    # its left side would report this write as harmless while it empties half the
    # answer.
    InvalidationPair.of(
      'a union, with a write only the far side of it consults',
      S[:posts].where(:id, 10).select(:title).union(S[:posts].where_at(:author, :city, 'tokyo').select(:title)),
      [DBW::UPDATE, [S[:users].where(:id, 1), { city: 'osaka' }]],
      disjoint: false, changed: true
    )
  ].freeze
end

# The property, driven over the table, in all three models.
class DBInvalidationConformanceTest < Minitest::Test
  include InvalidationModels

  def setup
    skip 'sqlite3 unavailable' unless INVALIDATION_SQLITE

    @models = models(INVALIDATION_SCHEMA, INVALIDATION_SEED)
  end

  InvalidationPairs::ALL.each do |pair|
    define_method("test_#{pair.method_name}") do
      # The declared verdict is asserted before the instance is touched, so a
      # pair cannot drift into being a different case than the one it is filed
      # under — a "disjoint" row that quietly stopped being disjoint would pass
      # the law below while measuring nothing.
      assert_equal pair.disjoint, pair.disjoint?, pair.explain

      @models.each { |name, model| measure(pair, name, model) }
    end
  end

  private

  # Read, perform, read again. The comparison is the result type's own: an
  # unordered arrow answers with a `Relation`, whose equality is set equality, so
  # a model handing its rows back in another order is still the same answer; an
  # ordered arrow answers with a `Listing`, whose equality is by sequence. Using
  # either one for the other would make this suite lie in both directions — it
  # would fail on an accidental reordering of a set, and it would pass a
  # reordering that the window on top of it then reads differently.
  def measure(pair, name, model)
    before = model.select(pair.query)

    # An empty answer is unchanged by everything, so a pair whose answer starts
    # empty proves the law about nothing.
    refute_empty before, "#{name}: #{pair.label} answers nothing before the operation"

    perform(model, pair.tag, pair.payload, pair.confirm_carrier)
    after = model.select(pair.query)
    verdict(pair, name, before, after)
  end

  def verdict(pair, name, before, after)
    return refute_equal before, after, "#{name}: #{pair.explain}" if pair.changed

    assert_equal before, after, "#{name}: #{pair.explain}"
  end
end

# What the comparison above is, made explicit, because the whole suite rests on
# it. A set that came back in another order is the same answer and a sequence
# that did is not, and both halves of that have to be true or the measurement is
# worthless in one direction or the other.
class DBInvalidationComparisonTest < Minitest::Test
  include InvalidationModels

  def setup
    skip 'sqlite3 unavailable' unless INVALIDATION_SQLITE

    @models = models(INVALIDATION_SCHEMA, INVALIDATION_SEED)
  end

  def test_an_unordered_answer_compares_as_a_set_and_an_ordered_one_as_a_sequence
    unordered = @models[:memory].select(INVALIDATION_SCHEMA[:users].select(:id, :name))
    ordered = @models[:memory].select(INVALIDATION_SCHEMA[:users].select(:id, :name).order(:name))

    assert_instance_of Sodalite::DB::Relation, unordered
    assert_instance_of Sodalite::DB::Listing, ordered
    assert_equal unordered, Sodalite::DB::Relation[unordered.rows.reverse]
    refute_equal ordered, Sodalite::DB::Listing[ordered.rows.reverse]
  end

  # And the three models really do have to be asked separately: they are three
  # lowerings, and "the answer did not change" measured in one of them is a claim
  # about that one.
  def test_the_property_is_measured_in_all_three_models
    assert_equal %i[memory sql sequel], @models.keys
    assert_instance_of Sodalite::DB::Memory, @models[:memory]
    assert_instance_of Sodalite::DB::Sql, @models[:sql]
    assert_instance_of Sodalite::DB::Sequel, @models[:sequel]
  end
end

# The imprecision, pinned as a property.
#
# The granularity stops at the column. An update that moves elements between the
# fibres of a map dirties that map, and a query that filters on the same map is
# therefore reported as possibly-stale — even when every element it moved was
# outside the fibre the query asked for, so the answer is exactly what it was.
#
# This is a **false positive, and it is the design**. The alternative is a
# calculus that reads the operand and the guard and decides which fibres were
# touched, which is a decision about data rather than about the value in hand,
# and the whole reason `reads` and `writes` are functions of values already held
# is that they never ask the database anything. So it is measured here and left
# alone: the calculus over-reports, it never under-reports, and an over-report
# costs a recomputation while an under-report serves a stale answer as fresh.
class DBInvalidationImprecisionTest < Minitest::Test
  include InvalidationModels

  def setup
    skip 'sqlite3 unavailable' unless INVALIDATION_SQLITE

    @models = models(INVALIDATION_SCHEMA, INVALIDATION_SEED)
  end

  def test_an_update_moving_rows_between_fibres_is_a_false_positive_the_calculus_keeps
    query = INVALIDATION_SCHEMA[:posts].where(:author, 1)
    payload = [INVALIDATION_SCHEMA[:posts].where(:author, 2), { author: 3 }]
    writes = Sodalite::DB.writes(Sodalite::DB::UPDATE, payload)

    # Both name `posts.author`: the query consults it, the update moves it. The
    # calculus says "possibly stale" and stops there.
    assert_equal ['posts.author'], writes.sort.map(&:to_s)
    assert_includes query.reads.map(&:to_s), 'posts.author'
    refute query.reads.disjoint?(writes), 'the imprecision is only interesting while the sets meet'

    @models.each do |name, model|
      before = model.select(query)
      moved = model.update(payload[0], payload[1])
      after = model.select(query)

      # The update really did move rows — otherwise this measures nothing.
      assert_equal 1, moved, name
      refute_empty before, name
      assert_equal before, after, "#{name}: the answer moved after all, so this is not a false positive"
    end
  end
end

# The one place the claim is genuinely scoped, and whether the scope is reachable.
#
# A finitely presented schema can declare a path equation, and `Query#follow`
# rewrites a trailing run of compositions to the shortest path the equations
# prove equal to it. The rewrite is sound relative to the *declared theory*,
# which is weaker than sound: on an instance that violates the equation, the path
# as written and the path it was rewritten to answer differently. So the question
# this file has to settle is whether that gap is reachable as an invalidation
# failure — whether a write to a morphism lying only on the path that was
# normalised away can be disjoint from `reads` and still move the answer.
#
# **Measured: it is not reachable.** Normalisation happens once, when the arrow
# is built, so the query *value* already carries the rewritten steps — and both
# `reads` and all three evaluators read those same steps. `reads` therefore
# describes exactly the path that is evaluated, and the two cannot disagree about
# which path that is.
#
# What the equation scopes is normalisation, not invalidation. The arrow the
# caller wrote and the arrow the schema rewrote it to are two different values;
# each one's `reads` is right about itself, and the tests below measure both
# sides so the difference is visible rather than argued. That difference is
# present with or without any write at all — it is the standing already stated in
# `Query#normalised` and measured by `equation_violations` — so it is a limit of
# the rewrite, and the invalidation calculus does not widen it.
class DBInvalidationPathEquationTest < Minitest::Test
  include InvalidationModels

  # `desks.room.floor = desks.floor` is the sharp presentation: the path that is
  # normalised away is the only thing that reaches `rooms` at all, so after the
  # rewrite that object leaves `reads` entirely — elements and morphisms both.
  # If any write could slip through the calculus, a write to `rooms` against this
  # arrow is where it would.
  EQUATION_SPEC = {
    floors: { id: :integer, name: :string },
    rooms: { id: :integer, floor: Sodalite::DB.fk(:floors) },
    desks: { id: :integer, room: Sodalite::DB.fk(:rooms), floor: Sodalite::DB.fk(:floors) }
  }.freeze

  PRESENTED = Sodalite::DB.schema(EQUATION_SPEC, equations: [[:desks, %i[room floor], %i[floor]]])
  FREE = Sodalite::DB.schema(EQUATION_SPEC)

  # Desk 1 says it is on floor 4 while its room says floor 7, so the declared
  # equation does not hold — which is the only instance on which the two paths
  # can answer differently.
  VIOLATING = {
    floors: [{ id: 4, name: 'ground' }, { id: 7, name: 'attic' }],
    rooms: [{ id: 100, floor: 7 }, { id: 101, floor: 4 }],
    desks: [{ id: 1, room: 100, floor: 4 }, { id: 2, room: 101, floor: 4 }]
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless INVALIDATION_SQLITE

    @collapsed = PRESENTED[:desks].follow(:room).follow(:floor)
    @as_written = FREE[:desks].follow(:room).follow(:floor)
  end

  # The premise: the rewrite happened, and the instance really does violate the
  # equation. Without both, everything below is about nothing.
  def test_the_rewrite_happened_on_an_instance_that_violates_the_equation
    assert_equal [%i[follow floor floors]], @collapsed.steps
    assert_equal [%i[follow room rooms], %i[follow floor floors]], @as_written.steps

    models(PRESENTED, VIOLATING).each do |name, model|
      assert_equal ['desks.id=1: room.floor = 7 but floor = 4'], model.equation_violations, name
      refute_predicate model, :satisfies_equations?
    end
  end

  # `reads` describes the path the query was normalised *to*, which is also the
  # path every model evaluates — so `rooms` is absent from both, together.
  def test_reads_describes_the_path_that_was_normalised_to_and_not_the_one_written
    assert_equal ['desks', 'desks.floor', 'floors', 'floors.id', 'floors.name'],
                 @collapsed.reads.sort.map(&:to_s)
    assert_equal ['desks', 'desks.room', 'floors', 'floors.id', 'floors.name', 'rooms', 'rooms.floor'],
                 @as_written.reads.sort.map(&:to_s)
  end

  # The scoped case, performed. A delete of the object the rewrite dropped is
  # disjoint from the collapsed arrow's reads, and the answer does not move —
  # in all three models — because the arrow that exists does not consult `rooms`.
  def test_a_delete_of_the_object_the_rewrite_dropped_is_disjoint_and_changes_nothing
    writes = Sodalite::DB.writes(Sodalite::DB::DELETE, PRESENTED[:rooms].where(:id, 100))

    assert_equal ['rooms'], writes.sort.map(&:to_s)
    assert @collapsed.reads.disjoint?(writes), 'the sets have to be disjoint for this to be the scoped case'

    models(PRESENTED, VIOLATING).each do |name, model|
      before = model.select(@collapsed)

      refute_empty before, name
      model.delete(PRESENTED[:rooms].where(:id, 100))

      assert_equal before, model.select(@collapsed), "#{name}: the normalised arrow's answer moved"
    end
  end

  # The same for a write to a morphism that lies only on the dropped path.
  def test_a_write_to_a_morphism_only_on_the_dropped_path_is_disjoint_and_changes_nothing
    payload = [PRESENTED[:rooms].where(:id, 100), { floor: 4 }]
    writes = Sodalite::DB.writes(Sodalite::DB::UPDATE, payload)

    assert_equal ['rooms.floor'], writes.sort.map(&:to_s)
    assert @collapsed.reads.disjoint?(writes)

    models(PRESENTED, VIOLATING).each do |name, model|
      before = model.select(@collapsed)
      model.update(payload[0], payload[1])

      assert_equal before, model.select(@collapsed), "#{name}: the normalised arrow's answer moved"
    end
  end

  # And the other side of it, which is what makes the finding a finding rather
  # than an absence. The *same* delete against the *same* spelling over a schema
  # that declared no equation is reported stale and does change the answer. So
  # the calculus is not blind to `rooms`: it is right about each arrow, and the
  # two arrows are different arrows.
  def test_the_same_write_against_the_arrow_as_written_is_reported_stale_and_does_change_it
    writes = Sodalite::DB.writes(Sodalite::DB::DELETE, FREE[:rooms].where(:id, 100))

    refute @as_written.reads.disjoint?(writes), 'the unrewritten arrow does consult rooms'

    models(FREE, VIOLATING).each do |name, model|
      before = model.select(@as_written)
      model.delete(FREE[:rooms].where(:id, 100))

      refute_equal before, model.select(@as_written), "#{name}: the arrow as written should have moved"
    end
  end

  # The reachability question asked the other way round: a write that takes a
  # satisfying instance to a violating one is still not an invalidation failure,
  # because the collapsed arrow never consulted the morphism that broke.
  SATISFIED = {
    floors: [{ id: 4, name: 'ground' }, { id: 7, name: 'attic' }],
    rooms: [{ id: 100, floor: 4 }, { id: 101, floor: 4 }],
    desks: [{ id: 1, room: 100, floor: 4 }, { id: 2, room: 101, floor: 4 }]
  }.freeze

  def test_a_write_that_breaks_the_equation_is_disjoint_and_still_changes_nothing
    payload = [PRESENTED[:rooms].where(:id, 100), { floor: 7 }]
    writes = Sodalite::DB.writes(Sodalite::DB::UPDATE, payload)

    assert @collapsed.reads.disjoint?(writes)

    models(PRESENTED, SATISFIED).each do |name, model|
      assert_empty model.equation_violations, name
      before = model.select(@collapsed)
      model.update(payload[0], payload[1])

      assert_equal before, model.select(@collapsed), name
      refute_empty model.equation_violations, "#{name}: the write was supposed to break the equation"
    end
  end
end
