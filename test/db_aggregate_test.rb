# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# The monoids are over `A`, and a nullable column is a map into `A + 1`. These
# are the tests of the elimination between the two: what the fold does with the
# `nothing`s, what an empty fold means, and what the fragment says about both.
class DBAggregateTest < Minitest::Test
  SQLITE = begin
    require 'sqlite3'
    true
  rescue LoadError
    false
  end

  SCHEMA = Sodalite::DB.schema(users: { id: :integer, name: :string, city: :string, score: :integer? })

  SEED = {
    users: [
      { id: 1, name: 'mina', city: 'tokyo', score: 3 },
      { id: 2, name: 'rin', city: 'tokyo', score: nil },
      { id: 3, name: 'ghost', city: 'osaka', score: nil }
    ]
  }.freeze

  # A fibre is a set of rows; the column read out of it is the map into `A + 1`.
  FIBRE = [{ id: 1, score: 3 }, { id: 2, score: nil }, { id: 3, score: 5 }].freeze
  ALL_NOTHING = [{ id: 1, score: nil }, { id: 2, score: nil }].freeze

  def aggregate(kind, field, name)
    Sodalite::DB::Aggregate.new(name: name, kind: kind, field: field)
  end

  # `total + nothing` and `nothing < best` are not arithmetic — they raise. The
  # `+ 1` is eliminated first, so the monoid only ever sees `A`, and the answer
  # is the one SQL gives by skipping NULLs.
  def test_a_fold_drops_the_nothings_before_it_combines
    assert_equal 8, aggregate(:sum, :score, :total).fold(FIBRE)
    assert_equal 3, aggregate(:min, :score, :lowest).fold(FIBRE)
    assert_equal 5, aggregate(:max, :score, :highest).fold(FIBRE)
  end

  # Nothing survives the elimination, so the fold is its identity: `0` for
  # `(N, +, 0)`, and the adjoined `nothing` for min/max.
  def test_a_fibre_that_is_all_nothing_folds_to_the_identity
    assert_equal 0, aggregate(:sum, :score, :total).fold(ALL_NOTHING)
    assert_nil aggregate(:min, :score, :lowest).fold(ALL_NOTHING)
    assert_nil aggregate(:max, :score, :highest).fold(ALL_NOTHING)
  end

  def test_an_empty_fibre_folds_to_the_identity_too
    assert_equal 0, aggregate(:count, nil, :people).fold([])
    assert_equal 0, aggregate(:sum, :score, :total).fold([])
    assert_nil aggregate(:min, :score, :lowest).fold([])
    assert_nil aggregate(:max, :score, :highest).fold([])
  end

  # `COUNT(*)` counts elements of the fibre, not of a column, so a row that is
  # `nothing` everywhere is still an element. The drop must not reach here.
  def test_count_counts_the_elements_of_the_fibre_not_of_a_column
    assert_equal 3, aggregate(:count, nil, :people).fold(FIBRE)
    assert_equal 2, aggregate(:count, nil, :people).fold(ALL_NOTHING)
  end

  # The defect itself: the moment `score` is declared `:integer?`, this fold met
  # a `nothing` and raised in the memory model while SQL quietly answered.
  def test_the_memory_model_folds_a_nullable_column_the_way_sql_would
    query = SCHEMA[:users].group(:city).count(:people).sum(:score, as: :total)
                          .min(:score, as: :lowest).max(:score, as: :highest)
    rows = Sodalite::DB.memory(SCHEMA, SEED).select(query).rows

    assert_equal({ city: 'tokyo', people: 2, total: 3, lowest: 3, highest: 3 },
                 rows.find { |row| row[:city] == 'tokyo' })
    assert_equal({ city: 'osaka', people: 1, total: 0, lowest: nil, highest: nil },
                 rows.find { |row| row[:city] == 'osaka' })
  end

  # One fragment, built in one place. The name is part of it: a fold with no
  # alias is not a column of the grouped relation.
  def test_the_fragment_is_the_fold_and_its_alias
    assert_equal 'COUNT(*) AS people', aggregate(:count, nil, :people).sql
    assert_equal 'COALESCE(SUM(score), 0) AS total', aggregate(:sum, :score, :total).sql
    assert_equal 'MIN(id) AS oldest', aggregate(:min, :id, :oldest).sql
    assert_equal 'MAX(id) AS newest', aggregate(:max, :id, :newest).sql
  end

  # The qualifier is the caller's, because the fold reads its column out of
  # whatever the caller aliased the image to. `count` has no column to qualify.
  def test_the_fragment_qualifies_the_column_the_caller_asks_it_to
    assert_equal 'COUNT(*) AS people', aggregate(:count, nil, :people).sql('g')
    assert_equal 'COALESCE(SUM(g.score), 0) AS total', aggregate(:sum, :score, :total).sql('g')
    assert_equal 'MIN(g.id) AS oldest', aggregate(:min, :id, :oldest).sql('g')
    assert_equal 'MAX(g.id) AS newest', aggregate(:max, :id, :newest).sql('g')
  end

  # Quoting belongs to a dialect, so it is threaded in rather than guessed at
  # here. Bare names are what you get when nobody threads one.
  def test_quoting_is_the_callers_too
    quote = ->(name) { %("#{name}") }

    assert_equal 'COUNT(*) AS "people"', aggregate(:count, nil, :people).sql(quote: quote)
    assert_equal 'MIN("id") AS "oldest"', aggregate(:min, :id, :oldest).sql(quote: quote)
    assert_equal 'COALESCE(SUM("g"."score"), 0) AS "total"',
                 aggregate(:sum, :score, :total).sql('g', quote: quote)
  end

  # The identity has to survive a real engine, or the two models agree only on
  # paper: `SUM` over an all-`nothing` fibre is `NULL` in SQL, and the fragment
  # is coalesced precisely so that it comes back as the monoid's `0`.
  def test_the_sql_model_agrees_with_the_monoid_about_an_all_nothing_fibre
    skip 'sqlite3 unavailable' unless SQLITE

    model = Sodalite::DB.sql(SCHEMA, Adapter.new).create_tables_for_test!
    SEED[:users].each { |row| model.insert(:users, row) }
    query = SCHEMA[:users].group(:city).sum(:score, as: :total).min(:score, as: :lowest)

    assert_equal Sodalite::DB.memory(SCHEMA, SEED).select(query), model.select(query)
    assert_equal({ city: 'osaka', total: 0, lowest: nil },
                 model.select(query).rows.find { |row| row[:city] == 'osaka' })
  end

  # `execute(sql, binds) -> rows` is the whole port.
  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end
end
