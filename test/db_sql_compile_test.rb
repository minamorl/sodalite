# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  COMPILE_SQLITE = true
rescue LoadError
  COMPILE_SQLITE = false
end

# What the hand-written model actually emits.
#
# `SQL.compile` is a pure function from an arrow to text and binds, so the whole
# compilation can be read as a value with no database in the room. That is not a
# convenience: the conformance suite can only say the three models *agree*, and
# agreeing on the wrong join is a thing three models can do. Here the join is the
# claim.
class DBSqlCompileTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(
    users: { id: :integer, name: :string, city: :string, nickname: :string? },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) },
    comments: { id: :integer, body: :string, post: Sodalite::DB.fk(:posts) }
  )

  # Every name here is reserved somewhere, including the foreign key column, so
  # nothing in this schema can be spelled bare.
  RESERVED = Sodalite::DB.schema(
    order: { id: :integer, select: :string },
    user: { id: :integer, group: :string, order: Sodalite::DB.fk(:order) }
  )

  def compile(query) = Sodalite::DB::SQL.compile(query)

  # --- the pullback -------------------------------------------------------
  # `f*(S)` is a subobject of the domain, so the join a composition would emit
  # is emitted and then *not* followed: the carrier's alias is still what the
  # projection and the later steps qualify against.

  def test_a_pullback_joins_along_the_morphism_and_leaves_the_carrier_alone
    sql, binds = compile(SCHEMA[:posts].where_at(:author, :city, 'tokyo').select(:title))

    assert_equal 'SELECT DISTINCT "t0"."title" FROM "posts" "t0" ' \
                 'JOIN "users" "t1" ON "t0"."author" = "t1"."id" WHERE "t1"."city" = ?', sql
    assert_equal %w[tokyo], binds
  end

  # A path of length n is n hops, each one a morphism out of the object the last
  # arrived at — and the comparison lands at the far end, not anywhere between.
  def test_a_path_of_length_two_chains_one_join_per_hop
    sql, binds = compile(SCHEMA[:comments].where_along(%i[post author], :city, 'tokyo'))

    assert_equal 'SELECT "t0"."id", "t0"."body", "t0"."post" FROM "comments" "t0" ' \
                 'JOIN "posts" "t1" ON "t0"."post" = "t1"."id" ' \
                 'JOIN "users" "t2" ON "t1"."author" = "t2"."id" WHERE "t2"."city" = ?', sql
    assert_equal %w[tokyo], binds
  end

  # The difference between the two operations, in one query: `t0` is still the
  # carrier when the `follow` runs, so the composition starts from posts rather
  # than from the users the pullback happened to join.
  def test_a_composition_after_a_pullback_moves_the_carrier_the_pullback_did_not
    sql, = compile(SCHEMA[:posts].where_at(:author, :city, 'tokyo').follow(:author))

    assert_equal 'SELECT DISTINCT "t2"."id", "t2"."name", "t2"."city", "t2"."nickname" FROM "posts" "t0" ' \
                 'JOIN "users" "t1" ON "t0"."author" = "t1"."id" ' \
                 'JOIN "users" "t2" ON "t0"."author" = "t2"."id" WHERE "t1"."city" = ?', sql
  end

  # Two pullbacks along one path take their own aliases. Both joins are along a
  # function, so `t1` and `t2` name the same row and the conjunction means what
  # it says; sharing the alias would be an optimization, and the walk is not
  # where optimizations get decided.
  def test_two_pullbacks_along_one_morphism_each_take_their_own_alias
    sql, binds = compile(SCHEMA[:posts].where_at(:author, :city, 'tokyo').where_at(:author, :name, 'mina'))

    assert_includes sql, 'JOIN "users" "t1" ON "t0"."author" = "t1"."id" ' \
                         'JOIN "users" "t2" ON "t0"."author" = "t2"."id"'
    assert_includes sql, 'WHERE "t1"."city" = ? AND "t2"."name" = ?'
    assert_equal %w[tokyo mina], binds
  end

  # A pullback is `where` formed along a path, so a subobject taken before it
  # still qualifies against the carrier and the binds stay in step order.
  def test_a_subobject_on_either_side_of_a_pullback_qualifies_against_the_carrier
    sql, binds = compile(SCHEMA[:posts].where(:title, 'hello').where_at(:author, :city, 'tokyo'))

    assert_includes sql, 'WHERE "t0"."title" = ? AND "t1"."city" = ?'
    assert_equal %w[hello tokyo], binds
  end

  # --- quoting ------------------------------------------------------------

  # Values were never the exposure — they are bound. A reserved word is: a table
  # called `order` and a column called `select` are names the schema was allowed
  # to choose, and a compiler that cannot spell them is refusing the schema.
  def test_every_identifier_the_compiler_emits_is_quoted
    sql, = compile(RESERVED[:user].where_at(:order, :select, 'x').select(:group))

    assert_equal 'SELECT DISTINCT "t0"."group" FROM "user" "t0" ' \
                 'JOIN "order" "t1" ON "t0"."order" = "t1"."id" WHERE "t1"."select" = ?', sql
  end

  def test_the_fold_and_the_presentation_quote_their_names_too
    sql, = compile(RESERVED[:user].group(:group).count(:order).having(:order, :gt, 1).order(:order, :desc))

    assert_includes sql, 'SELECT "g"."group", COUNT(*) AS "order" FROM ('
    assert_includes sql, ') "g" GROUP BY "g"."group" HAVING "order" > ? ' \
                         'ORDER BY "order" DESC NULLS LAST, "group" ASC NULLS LAST'
  end

  def test_the_statements_a_model_runs_quote_their_identifiers
    assert_equal 'CREATE TABLE "order" ("id" INTEGER PRIMARY KEY, "select" TEXT)',
                 Sodalite::DB::SQL.create_table_statement(RESERVED.table(:order))
    assert_equal ['INSERT INTO "order" ("id", "select") VALUES (?, ?)', [1, 'x']],
                 Sodalite::DB::SQL.insert_statement(RESERVED.table(:order), { id: 1, select: 'x' })
    assert_equal ['DELETE FROM "order" WHERE "id" IN (?, ?)', [1, 2]],
                 Sodalite::DB::SQL.delete_statements(RESERVED.table(:order), [1, 2]).first
  end

  # An embedded quote is doubled, which is how the standard escapes one — so a
  # name containing the delimiter closes nothing.
  def test_an_embedded_quote_is_doubled_rather_than_dropped
    assert_equal '"we""ird"', Sodalite::DB::SQL.quote('we"ird')
    assert_equal '"order"', Sodalite::DB::SQL.quote(:order)
  end

  # --- the window ---------------------------------------------------------

  # `LIMIT -1` was SQLite's way of saying "no limit", and Postgres rejects a
  # negative limit outright. Neither dialect's spelling of "no limit" parses in
  # the other — `LIMIT ALL` and a bare `OFFSET` are both Postgres-only — so the
  # bound emitted is the largest one both accept, which is a limit that cannot
  # limit anything.
  def test_an_offset_with_no_limit_is_spelled_without_a_dialects_no_limit
    sql, = compile(SCHEMA[:users].order(:name).offset(1))

    refute_includes sql, 'LIMIT -1'
    assert_includes sql, " LIMIT #{Sodalite::DB::SQL::UNBOUNDED} OFFSET 1"
  end

  def test_a_limit_with_no_offset_says_only_the_limit
    sql, = compile(SCHEMA[:users].order(:name).limit(2))

    assert(sql.end_with?(' LIMIT 2'))
  end

  # --- the image ----------------------------------------------------------

  # `SELECT DISTINCT` is how SQL spells image factorization, and phase one has
  # exactly one operation that gives it work: `follow` moves the carrier to a
  # codomain whose fibres can hold more than one element. The pullback's join is
  # taken along a function, so it repeats nothing.

  def test_the_image_is_taken_when_a_composition_or_a_projection_can_duplicate
    assert_includes compile(SCHEMA[:posts].follow(:author)).first, 'SELECT DISTINCT '
    assert_includes compile(SCHEMA[:posts].select(:title)).first, 'SELECT DISTINCT '
  end

  def test_the_image_is_not_taken_when_the_key_survives_and_nothing_composed
    refute_includes compile(SCHEMA[:users]).first, 'DISTINCT'
    refute_includes compile(SCHEMA[:posts].where_at(:author, :city, 'tokyo')).first, 'DISTINCT'
    refute_includes compile(SCHEMA[:posts].select(:title, :id)).first, 'DISTINCT'
  end

  # --- the fold -----------------------------------------------------------

  # One spelling of each fragment, and it comes from the monoid. `sum` is
  # coalesced because `SUM` over an all-`nothing` fibre is `NULL` while the
  # identity of `(N, +, 0)` is `0`; `min`/`max` need no repair, because `NULL`
  # is the identity they already adjoined.
  def test_each_fold_fragment_is_its_monoids_own_spelling
    sql, = compile(SCHEMA[:users].group(:city).count(:people).sum(:id, as: :total)
                                 .min(:id, as: :oldest).max(:id, as: :newest))

    assert_includes sql, 'COUNT(*) AS "people"'
    assert_includes sql, 'COALESCE(SUM("g"."id"), 0) AS "total"'
    assert_includes sql, 'MIN("g"."id") AS "oldest"'
    assert_includes sql, 'MAX("g"."id") AS "newest"'
  end

  # --- the schema ---------------------------------------------------------

  # A foreign key column holds the target's key, so it is declared with the
  # target's key type rather than with a guess that happens to be `INTEGER`.
  def test_a_foreign_key_column_is_declared_with_its_targets_key_type
    assert_equal 'CREATE TABLE "comments" ("id" INTEGER PRIMARY KEY, "body" TEXT, "post" INTEGER)',
                 Sodalite::DB::SQL.create_table_statement(SCHEMA.table(:comments))
  end

  # Every morphism compiles to a join whose probe side is the foreign key
  # column, so the index is part of what declaring the morphism meant.
  def test_every_foreign_key_column_gets_an_index_named_after_its_arrow
    assert_equal [['CREATE INDEX "index_posts_on_author" ON "posts" ("author")', []]],
                 Sodalite::DB::SQL.index_statements(SCHEMA.table(:posts))
    assert_equal [['CREATE INDEX "index_user_on_order" ON "user" ("order")', []]],
                 Sodalite::DB::SQL.index_statements(RESERVED.table(:user))
  end

  def test_an_object_with_no_morphisms_out_of_it_needs_no_indexes
    assert_empty Sodalite::DB::SQL.index_statements(SCHEMA.table(:users))
  end
end

# The two things about this model that are not text. How many rows a deletion
# removed, and whether the stored instance is a functor, are both measurements —
# they need a database to be measured against, so they live with the model
# rather than with the compilation.
class DBSqlModelTest < Minitest::Test
  SCHEMA = DBSqlCompileTest::SCHEMA

  SEED = {
    users: [{ id: 1, name: 'mina', city: 'tokyo', nickname: 'mi' },
            { id: 2, name: 'rin', city: 'osaka', nickname: nil }],
    posts: [{ id: 10, title: 'hello', author: 1 },
            { id: 11, title: 'again', author: 1 },
            { id: 12, title: 'hello', author: 2 }]
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless COMPILE_SQLITE

    @recorder = Recorder.new
    @model = Sodalite::DB.sql(SCHEMA, @recorder).create_tables_for_test!
    SEED.each { |table, rows| rows.each { |row| @model.insert(table, row) } }
    @recorder.statements.clear
  end

  def deletes = @recorder.statements.grep(/\ADELETE FROM/)
  def scopes = @recorder.statements.grep(/\A(BEGIN|COMMIT|ROLLBACK)\z/)

  # The count is what was removed, not what was found. The old one was taken
  # before the statement ran, so a dropped key made it report rows it had left
  # standing.
  def test_a_deletion_returns_the_rows_it_actually_removed
    assert_equal 2, @model.delete(SCHEMA[:posts].where(:author, 1))
    assert_equal [{ id: 12, title: 'hello', author: 2 }], @model.select(SCHEMA[:posts]).rows
    assert_equal 0, @model.delete(SCHEMA[:posts].where(:author, 1))
  end

  # `WHERE key IN ()` is not a subobject of anything; it is a syntax error. An
  # empty doomed set removes nothing by emitting nothing.
  def test_an_empty_subobject_deletes_nothing_by_saying_nothing
    assert_equal 0, @model.delete(SCHEMA[:posts].where(:title, 'ghost'))
    assert_empty deletes
  end

  # One scope, so a driver that dies partway leaves the whole subobject standing
  # rather than an arbitrary part of it gone.
  def test_a_deletion_is_one_scope
    @model.delete(SCHEMA[:posts].where(:title, 'hello'))

    assert_equal %w[BEGIN COMMIT], scopes
  end

  # The bound exists because every driver caps the placeholders one statement
  # may carry, so a deletion large enough to matter is the one that would fail.
  def test_a_large_key_list_is_chunked
    chunk = Sodalite::DB::Sql::DELETE_CHUNK
    (100...(100 + chunk + 1)).each { |id| @model.insert(:posts, { id: id, title: 'bulk', author: 1 }) }
    @recorder.statements.clear

    assert_equal chunk + 1, @model.delete(SCHEMA[:posts].where(:title, 'bulk'))
    assert_equal 2, deletes.size
  end

  # A deletion names rows of the carrier, so an arrow that is not a subobject of
  # them is refused — before anything runs, which is why nothing ran.
  def test_an_arrow_that_is_not_a_subobject_is_refused_before_any_statement
    assert_raises(Sodalite::DB::QueryError) { @model.delete(SCHEMA[:posts].select(:title)) }
    assert_raises(Sodalite::DB::QueryError) { @model.delete(SCHEMA[:users].order(:name).limit(1)) }
    assert_empty @recorder.statements
  end

  # A composition stays a subobject, but of the codomain — so it is said out
  # loud or it is refused.
  def test_removing_rows_of_a_codomain_has_to_be_meant
    moved = SCHEMA[:posts].where(:title, 'hello').follow(:author)

    assert_raises(Sodalite::DB::QueryError) { @model.delete(moved) }
    assert_equal 2, @model.delete(moved, confirm_carrier: :users)
    assert_empty @model.select(SCHEMA[:users]).rows
  end

  # A dangling foreign key is not a bad row. It is a failure to be a functor:
  # the morphism has no value at that element. Reported, never enforced — the
  # insert that made it went through.
  def test_the_functor_diagnostic_reports_a_morphism_with_no_value
    assert_predicate @model, :functor?

    @model.insert(:posts, { id: 99, title: 'orphan', author: 404 })

    refute_predicate @model, :functor?
    assert_equal ['posts.author=404 has no users'], @model.violations
  end

  # The sentence is the schema's, so the models cannot drift into two spellings
  # of one failure.
  def test_every_model_words_the_same_violation_identically
    memory = Sodalite::DB.memory(SCHEMA)
    SEED.each { |table, rows| rows.each { |row| memory.insert(table, row) } }
    [@model, memory].each { |model| model.insert(:posts, { id: 99, title: 'orphan', author: 404 }) }

    assert_equal memory.violations, @model.violations
  end

  def test_the_indexes_are_created_with_the_tables
    recorder = Recorder.new
    Sodalite::DB.sql(SCHEMA, recorder).create_tables_for_test!

    assert_includes recorder.statements, 'CREATE INDEX "index_posts_on_author" ON "posts" ("author")'
    assert_includes recorder.statements, 'CREATE INDEX "index_comments_on_post" ON "comments" ("post")'
  end

  # The same one-method port every other suite uses, with a tape on it — the
  # questions here are about which statements were emitted, not only about what
  # came back.
  class Recorder
    attr_reader :statements

    def initialize
      @db = SQLite3::Database.new(':memory:')
      @statements = []
    end

    def execute(sql, binds)
      @statements << sql
      @db.execute(sql, binds)
    end
  end
end
