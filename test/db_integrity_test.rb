# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  INTEGRITY_SQLITE = true
rescue LoadError
  INTEGRITY_SQLITE = false
end

# `schema.rb` calls referential integrity "not a rule about rows but the
# condition for an instance to be a functor at all". A database that lets the
# condition fail silently is one where that sentence is false, so the constraint
# is emitted rather than described — and these tests are what keep it emitted.
#
# The second half is the type of the column. A foreign key carries the key it
# points at, so a table keyed by a UUID string was a table nobody could
# reference: the column was declared `INTEGER`, and the row schema refused the
# only value that could ever go in it.
class DBIntegrityTest < Minitest::Test
  PAIR = {
    users: { id: :integer, name: :string },
    posts: { id: :integer, author: Sodalite::DB.fk(:users) }
  }.freeze

  UUID_KEYED = {
    users: { id: :string, name: :string },
    posts: { id: :integer, author: Sodalite::DB.fk(:users) }
  }.freeze

  def test_a_foreign_key_is_emitted_as_a_constraint
    schema = Sodalite::DB.schema(**PAIR)

    assert_equal 'CREATE TABLE posts (id INTEGER PRIMARY KEY, author INTEGER REFERENCES users(id))',
                 Sodalite::DB::SQL.create_table_statement(schema.table(:posts))
  end

  # The claim in schema.rb is that the column carries the *target's* key type.
  def test_a_foreign_key_column_carries_the_type_of_the_key_it_points_at
    schema = Sodalite::DB.schema(**UUID_KEYED)

    assert_equal :string, schema.table(:posts).fk_type(:author)
    assert_equal 'CREATE TABLE posts (id INTEGER PRIMARY KEY, author TEXT REFERENCES users(id))',
                 Sodalite::DB::SQL.create_table_statement(schema.table(:posts))
  end

  # And the row schema has to agree, or the only value that could go in the
  # column is the one the sieve rejects.
  def test_a_uuid_keyed_table_can_actually_be_referenced
    schema = Sodalite::DB.schema(**UUID_KEYED)
    model = Sodalite::DB.memory(schema)
    model.insert(:users, { id: 'u-1', name: 'mina' })
    model.insert(:posts, { id: 1, author: 'u-1' })

    assert_equal [{ id: 1, author: 'u-1' }], model.rows(:posts)
    assert_predicate model, :functor?
  end

  # Declaration order is not creation order: an inline REFERENCES needs its
  # codomain to exist already.
  def test_tables_are_created_after_what_they_point_at
    reversed = Sodalite::DB.schema(posts: PAIR[:posts], users: PAIR[:users])

    assert_equal %i[posts users], reversed.tables.keys
    assert_equal %i[users posts], reversed.creation_order.map(&:name)
  end

  def test_create_tables_works_when_the_referencing_table_is_declared_first
    skip 'sqlite3 unavailable' unless INTEGRITY_SQLITE

    reversed = Sodalite::DB.schema(posts: PAIR[:posts], users: PAIR[:users])

    Sodalite::DB.sql(reversed, Adapter.new).create_tables!
    Sodalite::DB.sequel(reversed, Sequel.sqlite).create_tables!
  end

  # SQLite parses REFERENCES but does not enforce it unless the connection asks,
  # so the pragma is part of the test rather than assumed. On Postgres and MySQL
  # the constraint is enforced without one.
  def test_the_database_refuses_a_dangling_reference
    skip 'sqlite3 unavailable' unless INTEGRITY_SQLITE

    adapter = Adapter.new(foreign_keys: true)
    Sodalite::DB.sql(Sodalite::DB.schema(**PAIR), adapter).create_tables!

    assert_raises(SQLite3::ConstraintException) do
      adapter.execute('INSERT INTO posts (id, author) VALUES (?, ?)', [1, 99])
    end
  end

  def test_the_sequel_model_refuses_it_too
    skip 'sqlite3 unavailable' unless INTEGRITY_SQLITE

    db = Sequel.sqlite
    db.run('PRAGMA foreign_keys = ON')
    model = Sodalite::DB.sequel(Sodalite::DB.schema(**PAIR), db).create_tables!

    assert_raises(Sequel::ForeignKeyConstraintViolation) { model.insert(:posts, { id: 1, author: 99 }) }
  end

  class Adapter
    def initialize(foreign_keys: false)
      @db = SQLite3::Database.new(':memory:')
      @db.execute('PRAGMA foreign_keys = ON', []) if foreign_keys
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end
end
