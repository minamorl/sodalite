# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  SQLITE = true
rescue LoadError
  SQLITE = false
end

# The claim the whole design rests on, made runnable.
#
# `Memory`, `Sql`, and `Sequel` are not a stub and two real things. They are
# three models of one finitely presented theory, and they agree across all three
# phases. A framework that says "the world is a parameter" should be able to
# check that its worlds are the same world; this is that check.
#
# `Memory` evaluates the composites, subobjects, and images directly in Set.
# `Sql` compiles arrows to SQL text with no driver anywhere near it. `Sequel`
# lowers the same arrows onto a dataset algebra that knows dialects and quoting.
# Three independent lowerings of one meaning — a bug would have to occur in all
# three, identically, to survive.
class DBConformanceTest < Minitest::Test
  # `comments -> posts -> users` is the shortest presentation with a path of
  # length two in it, which is what a pullback along more than one morphism
  # needs to have anything to walk.
  SCHEMA = Sodalite::DB.schema(
    users: { id: :integer, name: :string, city: :string, nickname: :string? },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) },
    comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) }
  )

  SEED = {
    users: [
      { id: 1, name: 'mina', city: 'tokyo', nickname: 'mi' },
      { id: 2, name: 'rin',  city: 'osaka', nickname: nil },
      { id: 3, name: 'ghost', city: 'tokyo', nickname: nil }
    ],
    posts: [
      { id: 10, title: 'hello', author: 1 },
      { id: 11, title: 'again', author: 1 },
      { id: 12, title: 'hello', author: 2 }
    ],
    # One comment on each side of the two-hop path: 20 reaches tokyo, 21 osaka.
    comments: [
      { id: 20, body: 'nice', post: 10 },
      { id: 21, body: 'hm', post: 12 }
    ]
  }.freeze

  # Arrows in the regular fragment: composition, subobjects, images, and the
  # composites of those.
  QUERIES = {
    'whole table' => ->(s) { s[:users] },
    'subobject' => ->(s) { s[:users].where(:city, 'tokyo') },
    'image' => ->(s) { s[:users].select(:city) },
    'subobject then image' => ->(s) { s[:users].where(:city, 'tokyo').select(:name) },
    'composition' => ->(s) { s[:posts].follow(:author) },
    'subobject then composition' => ->(s) { s[:posts].where(:title, 'hello').follow(:author) },
    'composition then subobject' => ->(s) { s[:posts].follow(:author).where(:city, 'tokyo') },
    'composition then image' => ->(s) { s[:posts].follow(:author).select(:name) },
    'the full composite' => lambda { |s|
      s[:posts].where(:title, 'hello').follow(:author).where(:city, 'tokyo').select(:name)
    },
    'image collapses duplicates' => ->(s) { s[:posts].select(:title) },
    'empty subobject' => ->(s) { s[:users].where(:city, 'kyoto') },

    # Phase two: a fold along the fibers of the grouping map.
    'group and count' => ->(s) { s[:users].group(:city).count(:people) },
    'group and max' => ->(s) { s[:users].group(:city).max(:id, as: :newest) },
    'group and sum' => ->(s) { s[:users].group(:city).sum(:id, as: :total) },
    'group and min' => ->(s) { s[:users].group(:city).min(:id, as: :oldest) },
    'several folds at once' => lambda { |s|
      s[:users].group(:city).count(:people).min(:id, as: :oldest).max(:id, as: :newest)
    },
    'fold after composition' => ->(s) { s[:posts].follow(:author).group(:city).count(:people) },
    'fold after a subobject' => ->(s) { s[:users].where(:city, 'tokyo').group(:city).count(:people) },
    'a fold with an empty carrier' => ->(s) { s[:users].where(:city, 'kyoto').group(:city).count(:people) },

    # Phase three: a total order, and a window on it.
    'order' => ->(s) { s[:users].order(:name) },
    'order descending' => ->(s) { s[:users].order(:name, :desc) },
    'order then window' => ->(s) { s[:users].order(:name).limit(2) },
    'order then offset window' => ->(s) { s[:users].order(:name).limit(2).offset(1) },
    'order by two fields' => ->(s) { s[:users].order(:city).order(:name, :desc) },
    'order a projection' => ->(s) { s[:users].select(:name, :id).order(:name) },
    'order a fold by its aggregate' => ->(s) { s[:users].group(:city).count(:people).order(:people, :desc) },
    'a window over a fold' => ->(s) { s[:users].group(:city).count(:people).order(:people, :desc).limit(1) },
    'the whole pipeline' => lambda { |s|
      s[:posts].where(:title, 'hello').follow(:author).group(:city).count(:people).order(:people, :desc)
    },

    # Order comparisons: subobjects wherever the attribute type carries an order.
    'greater than' => ->(s) { s[:users].where(:id, :gt, 1) },
    'at least' => ->(s) { s[:users].where(:id, :gte, 2) },
    'less than' => ->(s) { s[:users].where(:id, :lt, 3) },
    'at most' => ->(s) { s[:users].where(:id, :lte, 1) },
    'a string comparison' => ->(s) { s[:users].where(:name, :gt, 'm') },
    'a bounded range is two subobjects' => ->(s) { s[:users].where(:id, :gte, 1).where(:id, :lte, 2) },

    # The complement, only where the type is a plain set.
    'a complement' => ->(s) { s[:users].where(:city, :not, 'tokyo') },
    'a complement then a fold' => ->(s) { s[:users].where(:city, :not, 'tokyo').group(:city).count(:people) },

    # Eliminating `A + 1` explicitly, in both directions.
    'the fibre over nothing' => ->(s) { s[:users].where_null(:nickname) },
    'its complement' => ->(s) { s[:users].where_present(:nickname) },

    # The coproduct. SQL's UNION deduplicates, so it is set union.
    'a coproduct' => ->(s) { s[:users].where(:city, 'tokyo').union(s[:users].where(:city, 'osaka')) },
    'a coproduct that overlaps deduplicates' => lambda { |s|
      s[:users].where(:city, 'tokyo').union(s[:users].where(:id, :lte, 2))
    },
    'a coproduct of projections' => lambda { |s|
      s[:users].select(:city).union(s[:users].where(:id, 1).select(:city))
    },
    'a fold over a coproduct' => lambda { |s|
      s[:users].where(:city, 'tokyo').union(s[:users].where(:city, 'osaka')).group(:city).count(:people)
    },
    'an ordered coproduct' => lambda { |s|
      s[:users].where(:city, 'tokyo').union(s[:users].where(:city, 'osaka')).order(:name)
    },

    # A subobject of the grouped relation, which is a different set.
    'having' => ->(s) { s[:users].group(:city).count(:people).having(:people, :gt, 1) },
    'having on a group key' => ->(s) { s[:users].group(:city).count(:people).having(:city, :not, 'osaka') },
    'having then order' => lambda { |s|
      s[:users].group(:city).count(:people).having(:people, :gte, 1).order(:people, :desc)
    },

    # The pullback: `f*(S)` is a subobject of the *domain*, which is the one
    # thing `follow` cannot hand back. Every model has to agree about which side
    # of the span the answer is read from.
    'a pullback' => ->(s) { s[:posts].where_at(:author, :city, 'tokyo') },
    'a pullback then an image' => ->(s) { s[:posts].where_at(:author, :city, 'tokyo').select(:title) },
    'a pullback then a subobject' => lambda { |s|
      s[:posts].where_at(:author, :city, 'tokyo').where(:title, 'hello')
    },
    'a subobject then a pullback' => lambda { |s|
      s[:posts].where(:title, 'hello').where_at(:author, :city, 'tokyo').select(:title, :id)
    },
    'a pullback then a composition' => ->(s) { s[:posts].where_at(:author, :city, 'tokyo').follow(:author) },
    'two pullbacks along the same morphism' => lambda { |s|
      s[:posts].where_at(:author, :city, 'tokyo').where_at(:author, :name, 'mina')
    },
    'an empty pullback' => ->(s) { s[:posts].where_at(:author, :city, 'kyoto') },
    'a pullback along a path of length two' => lambda { |s|
      s[:comments].where_along(%i[post author], :city, 'tokyo')
    },
    'a two-hop pullback then an image' => lambda { |s|
      s[:comments].where_along(%i[post author], :city, 'tokyo').select(:body)
    },
    'a fold after a pullback' => lambda { |s|
      s[:posts].where_at(:author, :city, 'tokyo').group(:title).count(:posts)
    },

    # A window with no upper bound. Every dialect spells "no limit" differently
    # and the models have to land on the same rows regardless.
    'an offset with no limit' => ->(s) { s[:users].order(:name).offset(1) }
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless SQLITE

    @memory = Sodalite::DB.memory(SCHEMA, SEED)
    @sql = Sodalite::DB.sql(SCHEMA, Adapter.new).create_tables!
    @sequel = Sodalite::DB.sequel(SCHEMA, Sequel.sqlite).create_tables!
    SEED.each do |table, rows|
      rows.each { |row| [@sql, @sequel].each { |model| model.insert(table, row) } }
    end
  end

  QUERIES.each do |label, build|
    define_method("test_the_models_agree_on_#{label.tr(' ', '_')}") do
      query = build.call(SCHEMA)
      expected = @memory.select(query)

      assert_equal expected, @sql.select(query), "sql: #{query}\n#{Sodalite::DB::SQL.compile(query).first}"
      assert_equal expected, @sequel.select(query), "sequel: #{query}"
    end
  end

  # Composition is not a join you wrote. It is a join the compiler emitted
  # because that is how SQL spells composition.
  def test_following_a_morphism_compiles_to_a_join
    sql, binds = Sodalite::DB::SQL.compile(
      SCHEMA[:posts].where(:title, 'hello').follow(:author).where(:city, 'tokyo').select(:name)
    )

    assert_equal 'SELECT DISTINCT "t1"."name" FROM "posts" "t0" JOIN "users" "t1" ON "t0"."author" = "t1"."id" ' \
                 'WHERE "t0"."title" = ? AND "t1"."city" = ?', sql
    assert_equal %w[hello tokyo], binds
  end

  # The pullback emits the same join and reads the other side of the span: the
  # carrier's alias is still what the projection and the later steps qualify
  # against, so the answer is posts rather than users.
  def test_a_pullback_compiles_to_the_same_join_read_from_the_other_side
    sql, binds = Sodalite::DB::SQL.compile(SCHEMA[:posts].where_at(:author, :city, 'tokyo').select(:title))

    assert_equal 'SELECT DISTINCT "t0"."title" FROM "posts" "t0" JOIN "users" "t1" ON "t0"."author" = "t1"."id" ' \
                 'WHERE "t1"."city" = ?', sql
    assert_equal %w[tokyo], binds
  end

  def test_a_whole_row_result_is_typed_by_the_same_schema_that_types_a_response
    users = @memory.select(SCHEMA[:users].where(:name, 'mina')).typed

    assert_equal 1, users.size
    assert_equal 'tokyo', users.first.city
    assert_predicate users.first, :frozen?
  end

  # Ordering is not part of the algebra, so it changes the result *type*: an
  # ordered query yields a sequence, and sequences compare in order.
  def test_an_ordered_query_yields_a_sequence_and_an_unordered_one_yields_a_set
    assert_instance_of Sodalite::DB::Relation, @memory.select(SCHEMA[:users])
    assert_instance_of Sodalite::DB::Listing, @memory.select(SCHEMA[:users].order(:name))
    assert_equal(%w[ghost mina rin], @sql.select(SCHEMA[:users].order(:name)).map { |row| row[:name] })
  end

  # The image has to be taken before the fold, or a join's multiplicities get
  # counted instead of the elements of the image. This is the one the conformance
  # suite caught: nothing about the naive SQL looked wrong.
  def test_a_fold_after_a_composition_counts_the_image_not_the_join
    query = SCHEMA[:posts].follow(:author).group(:city).count(:people)

    assert_equal([{ city: 'osaka', people: 1 }, { city: 'tokyo', people: 1 }],
                 @memory.select(query).rows.sort_by { |row| row[:city] })
    assert_equal @memory.select(query), @sql.select(query)
    assert_includes Sodalite::DB::SQL.compile(query).first, 'FROM (SELECT DISTINCT'
  end

  def test_a_fold_compiles_to_group_by_and_an_order_to_a_total_order
    sql, = Sodalite::DB::SQL.compile(SCHEMA[:users].group(:city).count(:people).order(:people, :desc).limit(2))

    assert_equal 'SELECT "g"."city", COUNT(*) AS "people" FROM ' \
                 '(SELECT DISTINCT "t0"."id", "t0"."name", "t0"."city", "t0"."nickname" FROM "users" "t0") "g" ' \
                 'GROUP BY "g"."city" ORDER BY "people" DESC, "city" ASC LIMIT 2', sql
  end

  # The coproduct compiles to UNION, which deduplicates — so it is set union,
  # which is what a Relation means. Neither branch spells `DISTINCT` here: they
  # keep their carrier's key and take no composition, so the image is already
  # taken, and `UNION` would have taken it again anyway.
  def test_a_coproduct_compiles_to_union_and_a_having_to_having
    union, = Sodalite::DB::SQL.compile(SCHEMA[:users].where(:id, 1).union(SCHEMA[:users].where(:id, 2)))
    having, = Sodalite::DB::SQL.compile(SCHEMA[:users].group(:city).count(:people).having(:people, :gt, 1))

    assert_includes union, ' UNION SELECT "t0"."id", '
    refute_includes union, 'DISTINCT'
    assert_includes having, ' HAVING "people" > ?'
  end

  # Rollback is not a feature a model implements for the caller's benefit — it is
  # what `Err` means to a scope. All three mean the same thing by it: a snapshot,
  # a literal `ROLLBACK`, and `Sequel::Rollback`.
  def test_every_model_rolls_back_a_failed_scope_the_same_way
    [@memory, @sql, @sequel].each do |model|
      workflow = Sodalite::DB.atomically(
        :write,
        Berylx::Task[:insert] { |_lay, io| io.perform(Sodalite::DB::INSERT, [:posts, doomed_post]) } >>
          Berylx::Task[:fail] { |lay| lay.reject(:conflict, 'no') }
      )

      result = Berylx::Root[].call(workflow, handlers: Sodalite::DB.handlers(model))

      assert_instance_of Berylx::Err, result
      assert_empty model.select(SCHEMA[:posts].where(:title, 'doomed')).rows, model.class.name
    end
  end

  def doomed_post
    { id: 99, title: 'doomed', author: 1 }
  end

  # Minimal adapter over sqlite3: `execute(sql, binds) -> rows`. One method is
  # the entire port, which is why the gem depends on no driver.
  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end
end
