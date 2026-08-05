# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  IMAGE_SQLITE = true
rescue LoadError
  IMAGE_SQLITE = false
end

# Image factorization makes a new object, and phase one may only name the maps
# that object has. Getting this wrong does not fail — it splits the models, and
# each of them then answers a different question with a straight face.
#
# Measured before the refusals existed, on `users.select(:id)`:
#
#   .where(:city, 'tokyo')    memory []            sql/sequel [{id=>1},{id=>3}]
#   .where_null(:nickname)    memory every row     sql/sequel [{id=>1},{id=>3}]
#   .where_at(:author, …)     memory []            sql/sequel [{id=>10}]
#   .follow(:author)          memory whole rows    sql/sequel a parse error
#
# The in-memory model filters the tuple it has already projected and finds the
# field gone; both SQL models put the comparison in the `WHERE` of the very
# statement that does the projecting, so they filter the object the image came
# from. Neither reading is the image's own.
class DBImageClosureTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(
    users: { id: :integer, name: :string, city: :string, nickname: :string? },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  SEED = {
    users: [{ id: 1, name: 'mina', city: 'tokyo', nickname: nil },
            { id: 2, name: 'rin', city: 'osaka', nickname: 'r' },
            { id: 3, name: 'ghost', city: 'tokyo', nickname: nil }],
    posts: [{ id: 10, title: 'a', author: 1 }, { id: 11, title: 'b', author: 2 }]
  }.freeze

  class Adapter
    def initialize = @db = SQLite3::Database.new(':memory:')
    def execute(sql, binds) = @db.execute(sql, binds)
  end

  def setup
    skip 'sqlite3 unavailable' unless IMAGE_SQLITE

    @models = [Sodalite::DB.memory(SCHEMA),
               Sodalite::DB.sql(SCHEMA, Adapter.new).create_tables_for_test!,
               Sodalite::DB.sequel(SCHEMA, Sequel.sqlite).create_tables_for_test!]
    @models.each { |m| SEED.each { |table, rows| rows.each { |row| m.insert(table, row) } } }
  end

  # --- what the image no longer has -----------------------------------------

  def test_a_subobject_cannot_be_taken_along_a_map_the_projection_dropped
    error = assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].select(:id).where(:city, 'tokyo') }

    assert_match(/where names users.city, which the projection \[:id\] dropped/, error.message)
    assert_match(/the only maps out of it are the ones it kept/, error.message)
  end

  def test_the_elimination_of_a_nothing_is_a_subobject_too_and_obeys_the_same_rule
    %i[where_null where_present].each do |operation|
      error = assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].select(:id).public_send(operation, :nickname) }

      assert_match(/#{operation} names users.nickname, which the projection \[:id\] dropped/, error.message)
    end
  end

  def test_a_pullback_cannot_start_from_a_morphism_the_projection_dropped
    error = assert_raises(Sodalite::DB::QueryError) do
      SCHEMA[:posts].select(:id).where_at(:author, :city, 'tokyo')
    end

    assert_match(/where_along names posts.author, which the projection \[:id\] dropped/, error.message)
  end

  # A composition is refused whether or not the morphism survived the
  # projection: what is in hand after an image is a set of tuples, and a tuple
  # is not an element of the domain to compose from.
  def test_a_composition_cannot_be_taken_out_of_an_image_at_all
    [%i[id], %i[author]].each do |kept|
      error = assert_raises(Sodalite::DB::QueryError) { SCHEMA[:posts].select(*kept).follow(:author) }

      assert_equal 'follow cannot come after select — the image is a set of tuples, ' \
                   'and a tuple is not an element to compose from', error.message
    end
  end

  # --- what the image still has ---------------------------------------------

  def test_a_subobject_along_a_map_the_image_kept_is_the_images_own_and_all_three_agree
    query = SCHEMA[:users].select(:city).where(:city, 'tokyo')

    @models.each { |m| assert_equal [{ city: 'tokyo' }], m.select(query).rows, m.class.name }
  end

  def test_a_pullback_from_a_morphism_the_image_kept_is_taken_where_it_stands
    query = SCHEMA[:posts].select(:author).where_at(:author, :city, 'tokyo')

    @models.each { |m| assert_equal [{ author: 1 }], m.select(query).rows, m.class.name }
  end

  def test_the_projection_stops_applying_once_a_composition_has_moved_the_carrier
    query = SCHEMA[:posts].follow(:author).select(:name)

    @models.each do |m|
      assert_equal [{ name: 'mina' }, { name: 'rin' }], m.select(query).rows.sort_by { |r| r[:name] }, m.class.name
    end
  end

  # A reprojection is the image of an image, and it is the last one that says
  # what may be named afterwards.
  def test_the_last_projection_is_the_one_that_decides
    assert_equal [{ id: 1 }], @models.first.select(SCHEMA[:users].select(:id, :city).where(:city, 'tokyo')
                                                                 .select(:id).where(:id, 1)).rows
    assert_raises(Sodalite::DB::QueryError) { SCHEMA[:users].select(:id, :city).select(:id).where(:city, 'tokyo') }
  end
end
