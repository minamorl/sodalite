# frozen_string_literal: true

require 'test_helper'
require 'logger'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  DDL_STATEMENTS_SQLITE = true
rescue LoadError
  DDL_STATEMENTS_SQLITE = false
end

# `db_ddl_test.rb` asks whether every step kind produces statements at all. This
# asks what they say.
#
# There are two roads to one presentation — declare it and call `create_tables!`,
# or migrate to it — and a schema is only a schema if both arrive at the same
# database. So the statements are pinned as text: the identifiers a migration
# writes are quoted the way the compiler quotes them, the indexes a morphism asks
# for are created on both roads, and a column's default is declared where the
# backend can fill existing rows from the schema instead of rewriting them.
class DBDDLStatementsTest < Minitest::Test
  # Every name here is a reserved word, which is the point: the presentation is
  # allowed to say `order` and `group`, and the migration used to spell them bare.
  ORDER = { order: { id: :integer, group: :string } }.freeze
  PAIR = { order: { id: :integer, group: :string }, select: { id: :integer, group: :string } }.freeze
  FROM = { from: { id: :integer, group: :string, table: :string } }.freeze

  QUOTED = {
    create_table: [{}, [:create_table, :order, { id: :integer, group: :string }],
                   [['CREATE TABLE "order" ("id" INTEGER PRIMARY KEY, "group" TEXT)', []]]],
    drop_table: [ORDER, %i[drop_table order],
                 [['DROP TABLE "order"', []]]],
    rename_table: [ORDER, %i[rename_table order select],
                   [['ALTER TABLE "order" RENAME TO "select"', []]]],
    add_attribute: [ORDER, [:add_attribute, :order, :where, :string, 'unknown'],
                    [['ALTER TABLE "order" ADD COLUMN "where" TEXT DEFAULT \'unknown\'', []],
                     ['UPDATE "order" SET "where" = ? WHERE "where" IS NULL', ['unknown']]]],
    drop_attribute: [ORDER, %i[drop_attribute order group],
                     [['ALTER TABLE "order" DROP COLUMN "group"', []]]],
    rename_attribute: [ORDER, %i[rename_attribute order group select],
                       [['ALTER TABLE "order" RENAME COLUMN "group" TO "select"', []]]],
    merge_tables: [PAIR, [:merge_tables, %i[order select], :from, :table],
                   [['CREATE TABLE "from" ("id" INTEGER PRIMARY KEY, "group" TEXT, "table" TEXT)', []],
                    ['INSERT INTO "from" ("id", "group", "table") SELECT "id", "group", ? FROM "order"', ['order']],
                    ['DROP TABLE "order"', []],
                    ['INSERT INTO "from" ("id", "group", "table") SELECT "id", "group", ? FROM "select"', ['select']],
                    ['DROP TABLE "select"', []]]],
    split_table: [FROM, [:split_table, :from, :table, { 'order' => :order, 'select' => :select }],
                  [['CREATE TABLE "order" ("id" INTEGER PRIMARY KEY, "group" TEXT)', []],
                   ['INSERT INTO "order" ("id", "group") SELECT "id", "group" FROM "from" WHERE "table" = ?',
                    ['order']],
                   ['CREATE TABLE "select" ("id" INTEGER PRIMARY KEY, "group" TEXT)', []],
                   ['INSERT INTO "select" ("id", "group") SELECT "id", "group" FROM "from" WHERE "table" = ?',
                    ['select']],
                   ['DROP TABLE "from"', []]]]
  }.freeze

  def test_the_quoted_cases_cover_every_declared_step_kind
    assert_equal Sodalite::DB::STEP_KINDS.sort, QUOTED.keys.sort
  end

  def test_every_step_kind_quotes_every_name_it_writes
    QUOTED.each do |kind, (spec, args, expected)|
      assert_equal expected, ddl(spec, args), kind.to_s
    end
  end

  # --- the indexes a morphism asks for ------------------------------------
  # `Sql#create_tables!` creates them with the table. A table a migration made
  # used to get none, so the same presentation had different indexes depending
  # on which road reached it.

  USERS = { users: { id: :integer, name: :string } }.freeze
  POSTS = USERS.merge(posts: { id: :integer, title: :string }).freeze
  LINKED = USERS.merge(posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }).freeze

  def test_creating_an_object_creates_the_indexes_its_morphisms_ask_for
    statements = ddl(USERS, [:create_table, :posts,
                             { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }])

    assert_equal [['CREATE TABLE "posts" ("id" INTEGER PRIMARY KEY, "title" TEXT, "author" INTEGER)', []],
                  ['CREATE INDEX "index_posts_on_author" ON "posts" ("author")', []]], statements
  end

  def test_an_object_with_no_morphisms_out_of_it_gets_no_indexes
    statements = ddl({}, [:create_table, :users, { id: :integer, name: :string }])

    assert_equal [['CREATE TABLE "users" ("id" INTEGER PRIMARY KEY, "name" TEXT)', []]], statements
  end

  # Σ lands in one object, so one set of indexes, emitted with it and not once
  # per injection — `CREATE INDEX` has no `IF NOT EXISTS` and the second would
  # raise.
  def test_the_coproduct_indexes_the_object_it_lands_in_once
    herd = { users: { id: :integer, name: :string },
             cats: { id: :integer, name: :string, owner: Sodalite::DB.fk(:users) },
             dogs: { id: :integer, name: :string, owner: Sodalite::DB.fk(:users) } }
    statements = ddl(herd, [:merge_tables, %i[cats dogs], :animals, :species])

    assert_equal ['CREATE TABLE "animals" ("id" INTEGER PRIMARY KEY, "name" TEXT, "species" TEXT, "owner" INTEGER)',
                  'CREATE INDEX "index_animals_on_owner" ON "animals" ("owner")',
                  'INSERT INTO "animals" ("id", "name", "species", "owner") ' \
                  'SELECT "id", "name", ?, "owner" FROM "cats"',
                  'DROP TABLE "cats"',
                  'INSERT INTO "animals" ("id", "name", "species", "owner") ' \
                  'SELECT "id", "name", ?, "owner" FROM "dogs"',
                  'DROP TABLE "dogs"'], statements.map(&:first)
  end

  def test_the_decomposition_indexes_every_fibre
    animals = { users: { id: :integer, name: :string },
                animals: { id: :integer, name: :string, owner: Sodalite::DB.fk(:users), species: :string } }
    statements = ddl(animals, [:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }])

    assert_equal ['CREATE TABLE "cats" ("id" INTEGER PRIMARY KEY, "name" TEXT, "owner" INTEGER)',
                  'CREATE INDEX "index_cats_on_owner" ON "cats" ("owner")',
                  'INSERT INTO "cats" ("id", "name", "owner") SELECT "id", "name", "owner" ' \
                  'FROM "animals" WHERE "species" = ?',
                  'CREATE TABLE "dogs" ("id" INTEGER PRIMARY KEY, "name" TEXT, "owner" INTEGER)',
                  'CREATE INDEX "index_dogs_on_owner" ON "dogs" ("owner")',
                  'INSERT INTO "dogs" ("id", "name", "owner") SELECT "id", "name", "owner" ' \
                  'FROM "animals" WHERE "species" = ?',
                  'DROP TABLE "animals"'], statements.map(&:first)
  end

  def test_declaring_a_morphism_later_indexes_that_column
    statements = ddl(POSTS, [:add_attribute, :posts, :author, Sodalite::DB.fk(:users)])

    assert_equal [['ALTER TABLE "posts" ADD COLUMN "author" INTEGER', []],
                  ['CREATE INDEX "index_posts_on_author" ON "posts" ("author")', []]], statements
  end

  # Only that column. The object's other indexes are already there, so emitting
  # the whole set again would raise on the second name.
  def test_a_second_morphism_does_not_re_index_the_first
    statements = ddl(LINKED, [:add_attribute, :posts, :editor, Sodalite::DB.fk(:users)])

    assert_equal ['ALTER TABLE "posts" ADD COLUMN "editor" INTEGER',
                  'CREATE INDEX "index_posts_on_editor" ON "posts" ("editor")'], statements.map(&:first)
  end

  def test_an_attribute_is_not_a_morphism_and_gets_no_index
    statements = ddl(POSTS, %i[add_attribute posts body string])

    assert_equal [['ALTER TABLE "posts" ADD COLUMN "body" TEXT', []]], statements
  end

  # A step that does not make an object emits no index: the table it names
  # already has them, and there is no `IF NOT EXISTS` to make a repeat harmless.
  def test_nothing_but_a_creation_emits_an_index
    [%i[rename_table posts writings], %i[drop_attribute posts title],
     %i[rename_attribute posts title headline], %i[drop_table posts]].each do |args|
      refute(ddl(LINKED, args).any? { |sql, _binds| sql.include?('CREATE INDEX') }, args.first.to_s)
    end
  end

  # A foreign key column holds the target's key, so its type is the target's key
  # type. Calling it `INTEGER` was a lie the row schema does not tell.
  def test_a_morphism_into_a_string_keyed_object_is_text_not_integer
    tags = { tags: { id: :string, label: :string }, posts: { id: :integer, title: :string } }
    statements = ddl(tags, [:add_attribute, :posts, :tag, Sodalite::DB.fk(:tags)])

    assert_equal [['ALTER TABLE "posts" ADD COLUMN "tag" TEXT', []],
                  ['CREATE INDEX "index_posts_on_tag" ON "posts" ("tag")', []]], statements
  end

  # --- the default, and what filling it costs -----------------------------

  DEFAULTS = {
    7 => 'ALTER TABLE "posts" ADD COLUMN "mark" INTEGER DEFAULT 7',
    1.5 => 'ALTER TABLE "posts" ADD COLUMN "mark" REAL DEFAULT 1.5',
    'plain' => 'ALTER TABLE "posts" ADD COLUMN "mark" TEXT DEFAULT \'plain\'',
    "it's" => 'ALTER TABLE "posts" ADD COLUMN "mark" TEXT DEFAULT \'it\'\'s\'',
    true => 'ALTER TABLE "posts" ADD COLUMN "mark" TEXT DEFAULT true',
    false => 'ALTER TABLE "posts" ADD COLUMN "mark" TEXT DEFAULT false'
  }.freeze

  TYPES = { 7 => :integer, 1.5 => :float, 'plain' => :string, "it's" => :string,
            true => :boolean, false => :boolean }.freeze

  # On Postgres 11+ and on SQLite a declared default gives existing rows their
  # value without rewriting them, so the `UPDATE` has nothing left to do.
  def test_a_default_is_declared_in_the_ddl_and_rendered_by_kind
    DEFAULTS.each do |value, expected|
      statements = ddl(POSTS, [:add_attribute, :posts, :mark, TYPES.fetch(value), value])

      assert_equal expected, statements.first.first, value.inspect
    end
  end

  # A String is escaped the standard way — the quote is doubled — even though the
  # value came from the migration's own declaration rather than from a request.
  def test_a_string_default_doubles_an_embedded_quote
    statements = ddl(POSTS, [:add_attribute, :posts, :mark, :string, "it's"])

    assert_includes statements.first.first, "DEFAULT 'it''s'"
  end

  # A kind the renderer has not thought about raises rather than being
  # interpolated on the hope that it reads back.
  def test_a_default_whose_kind_has_no_literal_is_refused
    symbol = :soon
    error = assert_raises(Sodalite::DB::MigrationError) do
      ddl(POSTS, [:add_attribute, :posts, :mark, :string, symbol])
    end

    assert_match(/Symbol has no DDL literal/, error.message)
  end

  # The fallback for a backend the declaration did not satisfy. Narrowed to the
  # rows with no value, so it is a no-op wherever it did, and re-running it after
  # an interrupted migration cannot overwrite what has been written since.
  def test_the_backfill_only_names_the_rows_that_have_no_value
    statements = ddl(POSTS, [:add_attribute, :posts, :mark, :string, 'unknown'])

    assert_equal ['UPDATE "posts" SET "mark" = ? WHERE "mark" IS NULL', ['unknown']], statements.last
  end

  def test_no_default_means_no_backfill_at_all
    statements = ddl(POSTS, %i[add_attribute posts mark string])

    assert_equal [['ALTER TABLE "posts" ADD COLUMN "mark" TEXT', []]], statements
  end

  def ddl(spec, args)
    step = Sodalite::DB::Step[*args]
    Sodalite::DB::DDL.ddl(step, Sodalite::DB::Schema.new(step.apply(spec)))
  end
end

# Text that parses is not the claim; the claim is that a database ends up in the
# state the presentation describes. So the interesting statements are run — on
# both real backends, from empty, through `migrate!`.
class DBDDLStatementsRunTest < Minitest::Test
  EMPTY = Sodalite::DB::Schema.new({})

  # Reserved at every position a migration writes a name: the object, its
  # attributes, the attribute a rename lands on, and the column a morphism is.
  RESERVED = Sodalite::DB.history(
    [:create_table, :order, { id: :integer, group: :string }],
    [:add_attribute, :order, :where, :string, 'unknown'],
    %i[rename_attribute order where table],
    [:create_table, :select, { id: :integer, order: Sodalite::DB.fk(:order) }]
  )

  HERD = Sodalite::DB.history(
    [:create_table, :users, { id: :integer, name: :string }],
    [:create_table, :cats, { id: :integer, name: :string, owner: Sodalite::DB.fk(:users) }],
    [:create_table, :dogs, { id: :integer, name: :string, owner: Sodalite::DB.fk(:users) }],
    [:merge_tables, %i[cats dogs], :animals, :species]
  )

  FLOCK = { users: { id: :integer, name: :string },
            animals: { id: :integer, name: :string, owner: Sodalite::DB.fk(:users),
                       species: :string } }.freeze

  def setup
    skip 'sqlite3 unavailable' unless DDL_STATEMENTS_SQLITE
  end

  # The rows the backfill has to reach are the ones that were already there, so
  # they go in while the presentation is still the old one.
  def test_every_backend_migrates_a_reserved_word_schema_to_the_same_instance
    carried = carry(RESERVED, after: 1)
    carried.insert(:order, { id: 1, group: 'g' })
    carried.migrate!(RESERVED)
    carried.insert(:select, { id: 2, order: 1 })
    query = RESERVED.schema[:select].follow(:order).where(:group, 'g')

    assert_equal carried.memory.select(query), carried.sql.select(query)
    assert_equal carried.memory.select(query), carried.sequel.select(query)
    assert_equal 'unknown', carried.memory.select(RESERVED.schema[:order]).rows.first[:table]
  end

  # The row that existed before the column did ends up holding the default, on
  # both backends — which is the property the unconditional rewrite was buying
  # and the declared default has to keep buying.
  def test_a_declared_default_fills_the_rows_that_were_already_there
    carried = carry(RESERVED, after: 1)
    carried.insert(:order, { id: 1, group: 'g' })
    carried.migrate!(RESERVED)
    rows = RESERVED.schema[:order]

    assert_equal 'unknown', carried.sql.select(rows).rows.first[:table]
    assert_equal 'unknown', carried.sequel.select(rows).rows.first[:table]
  end

  # The Sequel backend has to pay the same cost, not merely answer the same
  # question — "the row ends up holding the default" is true of the full rewrite
  # too — so what it emits is read back off its own log. Sequel writes both
  # halves, because it owns the dialect and neither half is spelled here.
  def test_the_sequel_backend_declares_the_default_and_narrows_the_backfill
    carried = carry(RESERVED, after: 1)
    carried.insert(:order, { id: 1, group: 'g' })
    log = StringIO.new
    carried.db.loggers << Logger.new(log)
    carried.sequel.migrate!(RESERVED)

    assert_match(/ADD COLUMN `where` .+ DEFAULT \('unknown'\)/, log.string)
    assert_match(/UPDATE `order` SET `where` = 'unknown' WHERE \(`where` IS NULL\)/, log.string)
  end

  # The migration road and the `create_tables!` road name the same indexes,
  # which is the whole of audit 3.1: a table a migration made used to get none.
  def test_a_migration_creates_the_indexes_declaring_the_schema_would_have
    carried = carry(RESERVED, after: 0)
    carried.migrate!(RESERVED)
    declared = Adapter.new
    Sodalite::DB.sql(RESERVED.schema, declared).create_tables!

    assert_equal [%w[index_select_on_order], %w[index_select_on_order]], carried.indexes(:select)
    assert_equal %w[index_select_on_order], declared.indexes(:select)
  end

  # Σ makes one object, and the object it makes is indexed like one that was
  # declared. Running it at all is the check that the set is emitted once: a
  # second `CREATE INDEX` under the same name raises.
  def test_the_coproduct_arrives_indexed_and_keeps_its_elements
    carried = carry(HERD, after: 3)
    carried.insert(:users, { id: 1, name: 'mina' })
    carried.insert(:cats, { id: 2, name: 'mi', owner: 1 })
    carried.insert(:dogs, { id: 3, name: 'pochi', owner: 1 })
    carried.migrate!(HERD)
    query = HERD.schema[:animals].follow(:owner).select(:name)

    assert_equal [%w[index_animals_on_owner], %w[index_animals_on_owner]], carried.indexes(:animals)
    assert_equal carried.memory.select(query), carried.sql.select(query)
    assert_equal carried.memory.select(query), carried.sequel.select(query)
  end

  # The step is carried directly rather than through a `History`, because a
  # history that contains `split_table` beside any other object cannot be
  # planned: `Step#provides` answers for the whole resulting presentation, so
  # the split and the step that made the other object both claim its name and
  # the solver reads a cycle. A fibre only has a morphism out of it if there is
  # another object to point at, so the two cannot be had together — a
  # limitation of `migration.rb`, not of the statements under test.
  def test_every_fibre_of_the_decomposition_arrives_indexed_and_keeps_its_elements
    step = Sodalite::DB::Step[:split_table, :animals, :species, { 'cats' => :cats, 'dogs' => :dogs }]
    after = Sodalite::DB::Schema.new(step.apply(FLOCK))
    adapter = Adapter.new
    memory = Sodalite::DB.memory(Sodalite::DB::Schema.new(FLOCK))
    [Sodalite::DB.sql(Sodalite::DB::Schema.new(FLOCK), adapter).create_tables!, memory].each { |m| seed(m) }
    Sodalite::DB::DDL.ddl(step, after).each { |sql, binds| adapter.execute(sql, binds) }
    memory.carry(step)
    query = after[:cats].follow(:owner).select(:name)

    assert_equal %w[index_cats_on_owner], adapter.indexes(:cats)
    assert_equal %w[index_dogs_on_owner], adapter.indexes(:dogs)
    assert_equal memory.select(query), Sodalite::DB.sql(after, adapter).select(query)
  end

  # The two halves of the change, separated so each is visible. The declaration
  # fills the row that was already there — it reads the default before the
  # `UPDATE` behind it has run at all — and that `UPDATE` can then be run again
  # without undoing a write that came after it, which is what makes an
  # interrupted migration restartable.
  def test_the_declared_default_fills_the_rows_and_the_backfill_can_be_re_run
    db = SQLite3::Database.new(':memory:')
    db.execute('CREATE TABLE "order" ("id" INTEGER PRIMARY KEY, "group" TEXT)')
    db.execute('INSERT INTO "order" ("id", "group") VALUES (1, ?)', ['a'])
    step = Sodalite::DB::Step[:add_attribute, :order, :where, :string, 'unknown']
    schema = Sodalite::DB::Schema.new(step.apply(order: { id: :integer, group: :string }))
    declaration, backfill = Sodalite::DB::DDL.ddl(step, schema)
    db.execute(*declaration)

    assert_equal [%w[a unknown]], db.execute('SELECT "group", "where" FROM "order"')

    db.execute(*backfill)
    db.execute('UPDATE "order" SET "where" = ?', ['edited'])
    db.execute(*backfill)

    assert_equal [['edited']], db.execute('SELECT "where" FROM "order"')
  end

  def seed(model)
    model.insert(:users, { id: 1, name: 'mina' })
    model.insert(:animals, { id: 2, name: 'mi', owner: 1, species: 'cats' })
    model.insert(:animals, { id: 3, name: 'pochi', owner: 1, species: 'dogs' })
  end

  # Three models over one history. The prefix is carried first so rows can go in
  # under the old presentation, which is the only way the rest of the history has
  # anything to carry.
  def carry(history, after:)
    prefix = Sodalite::DB.history(*history.plan.order.first(after))
    adapter = Adapter.new
    db = Sequel.sqlite
    Backends.new(memory: Sodalite::DB.memory(Sodalite::DB::Schema.new(history.spec_after(after))),
                 sql: Sodalite::DB.sql(EMPTY, adapter).migrate!(prefix),
                 sequel: Sodalite::DB.sequel(EMPTY, db).migrate!(prefix),
                 adapter: adapter, db: db)
  end

  Backends = Data.define(:memory, :sql, :sequel, :adapter, :db) do
    def models = [memory, sql, sequel]
    def migrate!(history) = models.each { |model| model.migrate!(history) }
    def insert(table, row) = models.each { |model| model.insert(table, row) }

    # Both backends' answers, so one assertion says what each has *and* that
    # they agree: an index one emitter names and the other does not is the same
    # presentation arriving at two databases again.
    def indexes(table)
      [adapter.indexes(table), db.indexes(table).keys.map(&:to_s).sort]
    end
  end

  # Minimal adapter over sqlite3, plus the one reading a test needs that the
  # port does not carry: which indexes the database actually has.
  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end

    def indexes(table)
      @db.execute("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [table.to_s])
         .flatten.sort
    end
  end
end
