# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  SQLITE = true
rescue LoadError
  SQLITE = false
end

# The claim the whole design rests on, made runnable.
#
# `Memory` and `Sql` are not a stub and the real thing. They are two models of
# one finitely presented theory, and on the regular fragment they agree. A
# framework that says "the world is a parameter" should be able to check that its
# two worlds are the same world; this is that check.
class DBConformanceTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(
    users: { id: :integer, name: :string, city: :string },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  SEED = {
    users: [
      { id: 1, name: 'mina', city: 'tokyo' },
      { id: 2, name: 'rin',  city: 'osaka' },
      { id: 3, name: 'ghost', city: 'tokyo' }
    ],
    posts: [
      { id: 10, title: 'hello', author: 1 },
      { id: 11, title: 'again', author: 1 },
      { id: 12, title: 'hello', author: 2 }
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
    }
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless SQLITE

    @memory = Sodalite::DB.memory(SCHEMA, SEED)
    @sql = Sodalite::DB.sql(SCHEMA, Adapter.new).create_tables!
    SEED.each { |table, rows| rows.each { |row| @sql.insert(table, row) } }
  end

  QUERIES.each do |label, build|
    define_method("test_the_two_models_agree_on_#{label.tr(' ', '_')}") do
      query = build.call(SCHEMA)

      assert_equal @memory.select(query), @sql.select(query),
                   "#{query}\n#{Sodalite::DB::SQL.compile(query).first}"
    end
  end

  # Composition is not a join you wrote. It is a join the compiler emitted
  # because that is how SQL spells composition.
  def test_following_a_morphism_compiles_to_a_join
    sql, binds = Sodalite::DB::SQL.compile(
      SCHEMA[:posts].where(:title, 'hello').follow(:author).where(:city, 'tokyo').select(:name)
    )

    assert_equal 'SELECT DISTINCT t1.name FROM posts t0 JOIN users t1 ON t0.author = t1.id ' \
                 'WHERE t0.title = ? AND t1.city = ?', sql
    assert_equal %w[hello tokyo], binds
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

    assert_equal 'SELECT g.city, COUNT(*) AS people FROM ' \
                 '(SELECT DISTINCT t0.id, t0.name, t0.city FROM users t0) g ' \
                 'GROUP BY g.city ORDER BY people DESC, city ASC LIMIT 2', sql
  end

  # Rollback is not a feature either model implements for the caller's benefit —
  # it is what `Err` means to a scope. Both models mean the same thing by it, one
  # with a snapshot and one with a real `ROLLBACK`.
  def test_both_models_roll_back_a_failed_scope_the_same_way
    [@memory, @sql].each do |model|
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
