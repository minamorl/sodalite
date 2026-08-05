# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'
require 'logger'

begin
  require 'sqlite3'
  require 'sequel'
  SEQUEL_MODEL_SQLITE = true
rescue LoadError
  SEQUEL_MODEL_SQLITE = false
end

# What the Sequel model has to answer for on its own.
#
# The conformance suite checks that the three models agree, which is the claim
# that matters — but it can only check what all three can be asked. These are the
# ones where the answer lives in the lowering itself: which alias a step
# qualifies against, which statement the backend was actually handed, what the
# DDL declared a column to be, and what the instance says about being a functor.
#
# The schema is this file's own. `users.city` is a morphism into a table whose
# key is a **string**, which is the case that a foreign key column "is an
# integer" gets wrong, and `users.score` is nullable so a fibre can be entirely
# nothing — the case a `SUM` gets wrong.
class DBSequelTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(
    cities: { id: :string, country: :string },
    users: { id: :integer, name: :string, city: Sodalite::DB.fk(:cities), score: :integer? },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) },
    comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) }
  )

  SEED = {
    cities: [{ id: 'tokyo', country: 'jp' }, { id: 'osaka', country: 'jp' }],
    users: [
      { id: 1, name: 'mina', city: 'tokyo', score: 3 },
      { id: 2, name: 'rin', city: 'osaka', score: nil },
      { id: 3, name: 'ghost', city: 'tokyo', score: nil }
    ],
    posts: [
      { id: 10, title: 'hello', author: 1 },
      { id: 11, title: 'again', author: 1 },
      { id: 12, title: 'bye', author: 2 }
    ],
    comments: [{ id: 100, body: 'nice', post: 10 }, { id: 101, body: 'meh', post: 12 }]
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless SEQUEL_MODEL_SQLITE

    @db = Sequel.sqlite
    @model = Sodalite::DB.sequel(SCHEMA, @db).create_tables_for_test!
    SEED.each { |table, rows| rows.each { |row| @model.insert(table, row) } }
  end

  # What the backend was actually handed, rather than what it can be assumed to
  # have been handed. A lowering is a claim about statements, so the statements
  # are what some of these read.
  def logged
    io = StringIO.new
    @db.loggers = [Logger.new(io)]
    yield
    io.string
  ensure
    @db.loggers = []
  end

  def column_types(table)
    @db.schema(table).to_h { |column, info| [column, info[:type]] }
  end

  # --- the pullback -------------------------------------------------------

  # `f*(S)` is a subobject of the *carrier*. The join is the one composition
  # emits; what differs is which side of the span the rows come from, and these
  # are rows of posts.
  def test_a_pullback_yields_rows_of_the_carrier_not_of_the_target
    posts = @model.select(SCHEMA[:posts].where_at(:author, :name, 'mina'))

    assert_instance_of Sodalite::DB::Relation, posts
    assert_equal([{ id: 10, title: 'hello', author: 1 }, { id: 11, title: 'again', author: 1 }],
                 posts.rows.sort_by { |row| row[:id] })
    assert_equal 'hello', posts.typed.min_by(&:id).title
  end

  # A path of length two is two joins, and the comparison is made at the far end
  # of it — the carrier is still comments.
  def test_a_pullback_along_a_path_chains_the_joins
    query = SCHEMA[:comments].where_along(%i[post author], :name, 'mina')
    sql = logged { assert_equal [{ id: 100, body: 'nice', post: 10 }], @model.select(query).rows }

    assert_equal 2, sql.scan('INNER JOIN').size
  end

  # The alias is the whole difference between a pullback and a composition, so it
  # is checked where getting it wrong would still run: both tables have an `id`,
  # and a `where` that had moved to the target would answer with the empty set
  # instead of failing.
  def test_a_pullback_leaves_the_carrier_as_what_later_steps_qualify_against
    query = SCHEMA[:posts].where_at(:author, :id, 1).where(:id, 11)

    assert_equal [{ id: 11, title: 'again', author: 1 }], @model.select(query).rows
  end

  # It is not a fourth primitive. It composes with a subobject on either side of
  # it and with an image after it, because it *is* a `where` formed along a path.
  def test_a_pullback_composes_with_a_subobject_and_an_image
    projected = SCHEMA[:posts].where(:title, 'hello').where_at(:author, :city, 'tokyo').select(:title)
    collapsed = SCHEMA[:posts].where_at(:author, :city, 'tokyo').select(:author)

    assert_equal [{ title: 'hello' }], @model.select(projected).rows
    assert_equal [{ author: 1 }], @model.select(collapsed).rows
  end

  # A pullback is taken along a function, so every element has exactly one image
  # and the join cannot repeat a row of the carrier. Nothing to deduplicate.
  def test_a_pullback_repeats_no_element_of_the_carrier
    query = SCHEMA[:posts].where_at(:author, :city, 'tokyo')
    sql = logged { assert_equal [10, 11], @model.select(query).map { |row| row[:id] }.sort }

    refute_includes sql, 'DISTINCT'
  end

  # An element whose morphism has no value is in no fibre of it, so it is in no
  # pullback along it either — which is what the inner join already says. The
  # instance is not a functor while that row is there, and `violations` is where
  # that gets reported; the query does not pretend otherwise by keeping it.
  def test_an_element_whose_morphism_has_no_value_is_in_no_pullback
    @model.insert(:posts, { id: 13, title: 'ghostly', author: 99 })
    every_author = SCHEMA[:posts].where_at(:author, :id, :gte, 1)

    assert_equal [10, 11, 12], @model.select(every_author).map { |row| row[:id] }.sort
    refute_predicate @model, :functor?
  end

  # --- deletion -----------------------------------------------------------

  # The keys are how the rows are named, and a projection has dropped them. What
  # this used to do was delete nothing and report the size of the image.
  def test_delete_refuses_a_projection_because_the_keys_are_not_in_it
    error = assert_raises(Sodalite::DB::QueryError) { @model.delete(SCHEMA[:users].select(:name)) }

    assert_match(/the image is a set of tuples, not of rows/, error.message)
    assert_equal 3, @model.select(SCHEMA[:users]).size
  end

  # A composition stays inside the world of rows, but the rows are the codomain's.
  # Almost never what the caller meant, so it is said out loud or refused.
  def test_delete_through_a_composition_has_to_be_meant
    followed = SCHEMA[:posts].where(:title, 'bye').follow(:author)
    error = assert_raises(Sodalite::DB::QueryError) { @model.delete(followed) }

    assert_match(/pass confirm_carrier: :users to mean it/, error.message)
    assert_equal 1, @model.delete(followed, confirm_carrier: :users)
    assert_equal %w[ghost mina], @model.select(SCHEMA[:users]).map { |row| row[:name] }.sort
  end

  # The count is the backend's, not the size of a set measured a statement
  # earlier. Between the two there is another writer, and the honest number is
  # the one the `DELETE` did.
  def test_delete_reports_the_count_the_backend_reports
    assert_equal 2, @model.delete(SCHEMA[:posts].where(:author, 1))
    assert_equal([12], @model.select(SCHEMA[:posts]).map { |row| row[:id] })
  end

  # An empty subobject is not a `DELETE` with an empty list; it is nothing to do.
  def test_an_empty_subobject_issues_no_delete_at_all
    sql = logged { assert_equal 0, @model.delete(SCHEMA[:posts].where(:title, 'no such title')) }

    refute_includes sql, 'DELETE FROM'
    assert_equal 3, @model.select(SCHEMA[:posts]).size
  end

  # Reading the keys and deleting by them are two statements, so they are one
  # scope — and `atomically` joining an outer transaction is what makes that safe
  # to say from inside a model.
  def test_reading_the_keys_and_deleting_by_them_is_one_scope
    sql = logged { @model.delete(SCHEMA[:posts].where(:author, 1)) }

    assert_match(/BEGIN.*SELECT.*DELETE FROM.*COMMIT/m, sql)
  end

  # --- the fold -----------------------------------------------------------

  # `SUM` over a fibre whose column is entirely nothing is `NULL`; the monoid's
  # identity is `0`. The monoid is the pinned meaning, so the backend is brought
  # to it. No conformance query folds a nullable column, which is why this one is
  # here rather than there.
  def test_a_fold_of_a_column_that_is_entirely_nothing_is_the_monoids_identity
    query = SCHEMA[:users].group(:city).sum(:score, as: :total)

    assert_equal([{ city: 'osaka', total: 0 }, { city: 'tokyo', total: 3 }],
                 @model.select(query).rows.sort_by { |row| row[:city] })
  end

  # `min`/`max` need no such repair: `NULL` is the identity they already adjoined.
  def test_the_folds_that_already_adjoined_their_identity_are_left_alone
    query = SCHEMA[:users].group(:city).min(:score, as: :lowest).count(:people)

    assert_equal([{ city: 'osaka', lowest: nil, people: 1 }, { city: 'tokyo', lowest: 3, people: 2 }],
                 @model.select(query).rows.sort_by { |row| row[:city] })
  end

  # --- the DDL ------------------------------------------------------------

  # A foreign key column holds the target's key, so its type is the target's key
  # type. `cities.id` is a string, and calling `users.city` an integer would be a
  # lie the row schema does not tell — it validates against the same answer.
  def test_a_foreign_key_column_is_spelled_with_the_targets_key_type
    assert_equal :string, column_types(:users)[:city]
    assert_equal :integer, column_types(:posts)[:author]
    assert_equal :string, column_types(:cities)[:id]
    assert_equal 2, @model.select(SCHEMA[:users].where(:city, 'tokyo')).size
  end

  # `follow` and a pullback both compile to a join on the foreign key column, so
  # the index follows from the presentation rather than from tuning applied to it
  # afterwards. The name is spelled, not left to the adapter, because a name the
  # backend invents is one the other models cannot agree with.
  def test_every_morphism_gets_a_named_index_on_the_column_it_joins_on
    assert_equal({ index_posts_on_author: { unique: false, columns: [:author] } }, @db.indexes(:posts))
    assert_includes @db.indexes(:users), :index_users_on_city
    assert_includes @db.indexes(:comments), :index_comments_on_post
    assert_empty @db.indexes(:cities)
  end

  # --- image factorization ------------------------------------------------

  # `DISTINCT` is how SQL spells the image, and there is exactly one thing in
  # phase one that gives it work to do. Sorting for nothing is still sorting.
  def test_the_image_is_taken_only_where_there_is_one_to_take
    whole = logged { assert_equal 3, @model.select(SCHEMA[:users]).size }
    projected = logged { assert_equal 2, @model.select(SCHEMA[:users].select(:city)).size }
    followed = logged { assert_equal 2, @model.select(SCHEMA[:posts].follow(:author)).size }

    refute_includes whole, 'DISTINCT'
    assert_includes projected, 'SELECT DISTINCT'
    assert_includes followed, 'SELECT DISTINCT'
  end

  # --- the functor laws ---------------------------------------------------

  # A dangling foreign key is not a bad row: the morphism has no value at that
  # element, so the instance is not a functor. The sentence comes from the schema
  # so all three models report the same failure in the same words.
  def test_a_dangling_morphism_is_reported_in_the_schemas_own_words
    assert_predicate @model, :functor?
    assert_empty @model.violations

    @model.insert(:posts, { id: 13, title: 'ghostly', author: 99 })
    @model.insert(:comments, { id: 102, body: 'huh', post: 77 })

    refute_predicate @model, :functor?
    assert_equal [SCHEMA.dangling_message(:comments, :post, 77, :posts),
                  SCHEMA.dangling_message(:posts, :author, 99, :users)],
                 @model.violations.sort
    assert_includes @model.violations, 'posts.author=99 has no users'
  end

  # The boundary refuses a morphism with no value on the way in, so the only way
  # to hold one is a write that went around the model — which is the state a
  # diagnostic exists for. `NOT IN` over a null is `UNKNOWN`, so this is the row
  # the obvious query passes in silence.
  def test_a_morphism_with_no_value_at_all_is_dangling_too
    @db[:posts].insert(id: 14, title: 'orphan', author: nil)

    assert_equal [SCHEMA.dangling_message(:posts, :author, nil, :users)], @model.violations
    refute_predicate @model, :functor?
  end

  # It is a diagnostic, not an invariant. Nothing checks it on the way in, and
  # the DDL emits no `REFERENCES` — integrity here is a property of the instance
  # that can be asked about, and asking is the caller's move.
  def test_the_diagnostic_is_not_an_invariant_and_does_not_refuse_the_write
    assert_equal 13, @model.insert(:posts, { id: 13, title: 'ghostly', author: 99 })
    assert_equal 4, @model.select(SCHEMA[:posts]).size
    assert_equal 1, @model.delete(SCHEMA[:posts].where(:id, 13))
  end
end

# An index survives `RENAME TO` under the name it was created with, so a renamed
# object used to keep indexes named after the object it had been — a name nothing
# could compute again, and one a later object taking the freed name collided
# with. Both SQL models now carry the indexes across, and to the same names.
class DBSequelRenameIndexTest < Minitest::Test
  RENAMED = Sodalite::DB.history(
    [:create_table, :users, { id: :integer, name: :string }],
    [:create_table, :posts, { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }],
    [:rename_table, :posts, :writings]
  )

  def setup
    skip 'sqlite3 unavailable' unless SEQUEL_MODEL_SQLITE

    @db = Sequel.sqlite
    Sodalite::DB.sequel(Sodalite::DB::Schema.new({}), @db).migrate!(RENAMED)
  end

  def test_a_renamed_object_carries_its_indexes_to_names_that_can_be_computed_again
    assert_equal %i[index_writings_on_author], @db.indexes(:writings).keys
    refute @db.table_exists?(:posts)
  end

  # The name is one rule in one place, so the two SQL models cannot drift about
  # what a renamed object's indexes are called.
  def test_both_sql_models_name_the_carried_index_the_same_way
    connection = MigrationAdapter.new
    Sodalite::DB.sql(Sodalite::DB::Schema.new({}), connection).migrate!(RENAMED)
    hand_written = connection.execute('PRAGMA index_list("writings")', []).map { |row| row[1] }

    assert_equal hand_written.map(&:to_sym), @db.indexes(:writings).keys
  end

  class MigrationAdapter
    def initialize = @db = SQLite3::Database.new(':memory:')
    def execute(sql, binds) = @db.execute(sql, binds)
  end
end
