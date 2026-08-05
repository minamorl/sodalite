# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  EDGES_SQLITE = true
rescue LoadError
  EDGES_SQLITE = false
end

EDGES_EMPTY = Sodalite::DB::Schema.new({})

# The one-method port, with the one extra question this file has to ask: which
# objects the database is actually holding. That is not the same question as
# which objects the model's presentation names, and after a step that was refused
# it is the only one worth asking.
class EdgesAdapter
  def initialize
    @db = SQLite3::Database.new(':memory:')
  end

  def execute(sql, binds)
    @db.execute(sql, binds)
  end

  def tables
    execute("SELECT name FROM sqlite_master WHERE type = 'table'", []).flatten.map(&:to_sym)
  end
end

# The conformance suite next door drives arrow shapes through `Memory`, `Sql`,
# and `Sequel` and asserts they agree. Its presentation cannot say two things,
# and both of them are where a disagreement actually shipped: a nullable
# *numeric* column, whose fold meets `A + 1` at a monoid that has no answer for
# it, and an object keyed by a string, whose morphisms carry a column that is not
# the integer a foreign key is assumed to be.
#
# So this is the same check over a presentation that can say them. `Memory`
# evaluates in Set, `Sql` compiles to text, `Sequel` lowers onto a dataset
# algebra — three independent lowerings, and a defect would have to occur in all
# three identically to survive. Each model has been asked these questions alone;
# what was never asked is whether the three answers are one answer.
class DBConformanceEdgesTest < Minitest::Test
  # `cities` is keyed by a string, so `users.city` is a morphism whose column
  # holds one. `users.score` is a map into `A + 1`, so a fibre of the grouping
  # map can be entirely nothing.
  SCHEMA = Sodalite::DB.schema(
    cities: { id: :string, country: :string },
    users: { id: :integer, name: :string, city: Sodalite::DB.fk(:cities), score: :integer? },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  # The three shapes a fold along the fibres of `city` can meet: tokyo mixes a
  # value with a nothing, osaka is nothing the whole way down, and kyoto is an
  # element of the codomain that nothing maps to, so it is in no fibre at all.
  SEED = {
    cities: [{ id: 'tokyo', country: 'jp' }, { id: 'osaka', country: 'jp' }, { id: 'kyoto', country: 'jp' }],
    users: [
      { id: 1, name: 'mina', city: 'tokyo', score: 3 },
      { id: 2, name: 'rin', city: 'tokyo', score: nil },
      { id: 3, name: 'ghost', city: 'osaka', score: nil }
    ],
    posts: [
      { id: 10, title: 'hello', author: 1 },
      { id: 11, title: 'again', author: 1 },
      { id: 12, title: 'bye', author: 3 }
    ]
  }.freeze

  QUERIES = {
    # `SUM` over a fibre whose column is entirely nothing is `NULL`, and the
    # identity of `(N, +, 0)` is `0`. The monoid is the pinned meaning, so a
    # backend that answers otherwise is brought to it — and that repair is only
    # a claim about the design if all three are asked in one place.
    'a sum over a nullable column' => ->(s) { s[:users].group(:city).sum(:score, as: :total) },
    'every fold over a nullable column at once' => lambda { |s|
      s[:users].group(:city).count(:people).sum(:score, as: :total)
               .min(:score, as: :lowest).max(:score, as: :highest)
    },
    'a fold over a fibre that is entirely nothing' => lambda { |s|
      s[:users].where(:city, 'osaka').group(:city).sum(:score, as: :total).min(:score, as: :lowest)
    },
    # The identity has to survive a subobject of the grouped relation too. An
    # uncoalesced `NULL >= 0` is UNKNOWN, so the fibre falls out of a subobject
    # the monoid says it is in, while the model that folds in Set keeps it.
    'a subobject of a fold over a nullable column' => lambda { |s|
      s[:users].group(:city).sum(:score, as: :total).having(:total, :gte, 0)
    },
    'a fold over a nullable column after a composition' => lambda { |s|
      s[:posts].follow(:author).group(:city).sum(:score, as: :total)
    },
    'an order on a fold over a nullable column' => lambda { |s|
      s[:users].group(:city).sum(:score, as: :total).order(:total, :desc)
    },
    'a nullable column eliminated before the fold' => lambda { |s|
      s[:users].where_present(:score).group(:city).sum(:score, as: :total)
    },
    'the fibre of a nullable column over nothing' => ->(s) { s[:users].where_null(:score) },

    # The string key. A morphism into an object keyed by a string is the case a
    # column that "is an integer" gets wrong, and every phase walks across it:
    # the composition's join, the pullback's join read from the other side, the
    # comparison the column's own type decides, and the fold along the morphism.
    'a composition into a string-keyed object' => ->(s) { s[:users].follow(:city) },
    'a subobject after a composition into a string-keyed object' => lambda { |s|
      s[:users].follow(:city).where(:country, 'jp')
    },
    'a subobject on a string-keyed morphism column' => ->(s) { s[:users].where(:city, 'tokyo') },
    'an order comparison on a string-keyed morphism column' => ->(s) { s[:users].where(:city, :gt, 'p') },
    'a pullback across a string key' => ->(s) { s[:users].where_at(:city, :country, 'jp') },
    'a pullback across a string key then an image' => lambda { |s|
      s[:users].where_at(:city, :id, 'tokyo').select(:name)
    },
    'a two-hop pullback ending at a string key' => lambda { |s|
      s[:posts].where_along(%i[author city], :country, 'jp')
    },
    'a fold along a string-keyed morphism' => ->(s) { s[:users].group(:city).count(:people) },
    'the whole pipeline over a string key' => lambda { |s|
      s[:posts].follow(:author).where_at(:city, :country, 'jp').group(:city).count(:people)
    }
  }.freeze

  # Deleting through an arrow means naming rows of the carrier, so the arrow has
  # to *be* a subobject of them. Each model names the doomed rows its own way — a
  # rejection over Hashes, a `DELETE ... WHERE key IN`, a dataset — so an arrow
  # that leaves that world names three different sets rather than none, and for a
  # projection the third is usually empty while the count says otherwise. The
  # refusal is one sentence or it is three refusals.
  REFUSED_DELETES = {
    'an image' => [->(s) { s[:users].select(:name) },
                   'delete needs a subobject of users, and select is not one — ' \
                   'the image is a set of tuples, not of rows'],
    'an ordered image' => [->(s) { s[:users].select(:name, :id).order(:name) },
                           'delete needs a subobject of users, and select is not one — ' \
                           'the image is a set of tuples, not of rows'],
    'a windowed image' => [->(s) { s[:users].select(:name, :id).order(:name).limit(1) },
                           'delete needs a subobject of users, and select is not one — ' \
                           'the image is a set of tuples, not of rows'],
    'a presentation' => [->(s) { s[:users].order(:name) },
                         'delete needs a subobject of users, and order is not one — ' \
                         'a window on a deletion is not a subobject'],
    'a window' => [->(s) { s[:users].order(:name).limit(1) },
                   'delete needs a subobject of users, and order is not one — ' \
                   'a window on a deletion is not a subobject'],
    'a fold' => [->(s) { s[:users].group(:city).count(:people) },
                 'delete needs a subobject of users, and group is not one — a fold yields groups, not rows']
  }.freeze

  def setup
    skip 'sqlite3 unavailable' unless EDGES_SQLITE

    @db = Sequel.sqlite
    @memory = Sodalite::DB.memory(SCHEMA, SEED)
    @sql = Sodalite::DB.sql(SCHEMA, EdgesAdapter.new).create_tables_for_test!
    @sequel = Sodalite::DB.sequel(SCHEMA, @db).create_tables_for_test!
    SEED.each do |table, rows|
      rows.each { |row| [@sql, @sequel].each { |model| model.insert(table, row) } }
    end
  end

  def models
    [@memory, @sql, @sequel]
  end

  def sizes(table)
    models.map { |model| model.select(SCHEMA[table]).size }
  end

  def values(table, field)
    models.map { |model| model.select(SCHEMA[table]).map { |row| row[field] }.sort }
  end

  QUERIES.each do |label, build|
    define_method("test_the_models_agree_on_#{label.tr(' ', '_')}") do
      query = build.call(SCHEMA)
      expected = @memory.select(query)

      assert_equal expected, @sql.select(query), "sql: #{query}\n#{Sodalite::DB::SQL.compile(query).first}"
      assert_equal expected, @sequel.select(query), "sequel: #{query}"
    end
  end

  # --- deleting through an arrow --------------------------------------------

  REFUSED_DELETES.each do |label, (build, message)|
    define_method("test_every_model_refuses_a_delete_through_#{label.tr(' ', '_')}") do
      query = build.call(SCHEMA)
      messages = models.map do |model|
        assert_raises(Sodalite::DB::QueryError, model.class.name) { model.delete(query) }.message
      end

      assert_equal [message], messages.uniq
      assert_equal [3, 3, 3], sizes(:users)
    end
  end

  # `order` and `limit` are refused when the arrow is built, so there is no
  # per-model reading of them left to disagree about — which is a stronger
  # statement than three models agreeing, and the reason the table above can only
  # ask about `delete`.
  def test_an_order_and_a_window_over_an_image_are_refused_before_any_model_sees_them
    projected = SCHEMA[:users].select(:name)

    assert_match(/cannot be made total/,
                 assert_raises(Sodalite::DB::QueryError) { projected.order(:name) }.message)
    assert_match(/limit needs an order/,
                 assert_raises(Sodalite::DB::QueryError) { projected.limit(1) }.message)
    assert_match(/offset needs an order/,
                 assert_raises(Sodalite::DB::QueryError) { projected.offset(1) }.message)
  end

  # A composition stays inside the world of rows, but the rows are the codomain's
  # — so it is said out loud or it is refused. Once it is said, the three have to
  # remove the same elements *and* answer with the same number, which is a claim
  # about the count as much as about what is left.
  def test_every_model_refuses_a_delete_through_a_composition_until_the_carrier_is_named
    query = SCHEMA[:users].where(:city, 'osaka').follow(:city)
    messages = models.map do |model|
      assert_raises(Sodalite::DB::QueryError, model.class.name) { model.delete(query) }.message
    end

    assert_equal ['delete over users would remove rows of cities — pass confirm_carrier: :cities to mean it'],
                 messages.uniq
    assert_equal [3, 3, 3], sizes(:cities)
    assert_equal([1, 1, 1], models.map { |model| model.delete(query, confirm_carrier: :cities) })
    assert_equal [%w[kyoto tokyo]] * 3, values(:cities, :id)
  end

  # A pullback does not move the carrier, so a delete through one removes rows of
  # the object that was asked about — across a string key exactly as across any
  # other, because the key's type is not what decides which side of the span the
  # answer is read from.
  def test_every_model_deletes_the_same_rows_through_a_pullback_across_a_string_key
    query = SCHEMA[:users].where_at(:city, :id, 'osaka')

    assert_equal([1, 1, 1], models.map { |model| model.delete(query) })
    assert_equal [%w[mina rin]] * 3, values(:users, :name)
    assert_equal [3, 3, 3], sizes(:cities)
  end

  # --- a morphism into a string-keyed object --------------------------------

  # A foreign key column holds the target's key, so its type is the target's key
  # type. The three models spell that in three places — a `CREATE TABLE` the
  # hand-written one emits, a catalogue the backend keeps, and a row type the
  # in-memory one validates against — and all three read it off the one accessor
  # that resolves it, so `INTEGER` cannot appear in one of them alone. The column
  # order is the object's own: attributes are the morphisms into leaf objects and
  # come first, then the morphisms into objects of the category.
  def test_every_model_spells_a_string_keyed_morphism_with_the_targets_key_type
    assert_equal :string, SCHEMA.table(:users).column_type(:city)
    assert_equal 'CREATE TABLE "users" ("id" INTEGER PRIMARY KEY, "name" TEXT, "score" INTEGER, "city" TEXT)',
                 Sodalite::DB::SQL.create_table_statement(SCHEMA.table(:users))
    assert_equal :string, @db.schema(:users).to_h { |column, info| [column, info[:type]] }[:city]
    assert_equal :string, SCHEMA.table(:users).row_schema.spec[:city]
  end

  # The row type validates against that same answer, so the lie is inside the
  # validation boundary rather than beside it: a row carrying an integer where
  # the morphism's column carries a string never enters any of the three, and
  # they refuse it in one sentence.
  def test_every_model_refuses_a_row_whose_morphism_does_not_carry_the_targets_key
    messages = models.map do |model|
      assert_raises(Sodalite::DB::SchemaError, model.class.name) do
        model.insert(:users, { id: 4, name: 'kei', city: 7, score: nil })
      end.message
    end

    assert_equal 1, messages.uniq.size, messages.inspect
    assert_match(%r{/city: expected string}, messages.first)
    assert_equal [3, 3, 3], sizes(:users)
  end

  # A morphism with no value at an element is a failure to be a functor, and the
  # sentence belongs to the schema so one broken arrow cannot come back as three.
  # Across a string key the readings differ most: a set difference over Hashes,
  # two arrows and a rejection, and `exclude ... or IS NULL`.
  def test_every_model_reports_a_dangling_string_key_in_the_schemas_own_words
    models.each do |model|
      model.insert(:users, { id: 4, name: 'kei', city: 'nara', score: nil })

      refute_predicate model, :functor?, model.class.name
      assert_equal [SCHEMA.dangling_message(:users, :city, 'nara', :cities)], model.violations, model.class.name
    end
  end
end

# A step *is* its content, so its address is a function of that content and of
# nothing else — and a Hash is an unordered map, so permuting the fields of a
# `create_table` changes no presentation. The digest half of that is checked
# where the digest lives. This is the half that costs a database: the ledger is
# keyed by the address, so two spellings of one step have to be one row in all
# three models, or a refactor is an unapplied migration that `verify!` refuses to
# boot past.
class DBConformanceLedgerAddressTest < Minitest::Test
  DECLARED = Sodalite::DB.history(
    [:create_table, :users, { id: :integer, name: :string, city: :string }],
    [:create_table, :posts, { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }]
  )

  # The same two objects with their fields typed in another order, which is the
  # same presentation and therefore has to be the same history.
  REORDERED = Sodalite::DB.history(
    [:create_table, :users, { city: :string, name: :string, id: :integer }],
    [:create_table, :posts, { author: Sodalite::DB.fk(:users), title: :string, id: :integer }]
  )

  def models
    skip 'sqlite3 unavailable' unless EDGES_SQLITE

    [Sodalite::DB.memory(EDGES_EMPTY),
     Sodalite::DB.sql(EDGES_EMPTY, EdgesAdapter.new),
     Sodalite::DB.sequel(EDGES_EMPTY, Sequel.sqlite)]
  end

  def test_the_two_spellings_are_one_history
    assert_equal DECLARED.fingerprints.sort, REORDERED.fingerprints.sort
  end

  def test_a_history_migrated_under_one_spelling_verifies_under_the_other
    models.each do |model|
      model.migrate!(DECLARED)

      assert_same model, model.verify!(REORDERED), model.class.name
      assert_equal DECLARED.fingerprints.sort, model.applied.keys.sort, model.class.name
    end
  end

  # And it is one ledger *entry*, not two rows that both happen to verify:
  # migrating the other spelling afterwards finds the step already applied and
  # carries nothing — which a backend would say for itself, loudly, by refusing
  # to create a table that is already there.
  def test_migrating_the_other_spelling_afterwards_carries_and_records_nothing
    models.each do |model|
      model.migrate!(DECLARED)
      model.migrate!(REORDERED)

      assert_equal DECLARED.size, model.applied.size, model.class.name
      assert_equal %i[posts users], model.schema.names.sort, model.class.name
    end
  end
end

# `split_table` with a tag the decomposition does not list, and `merge_tables`
# over sources that share a key, are refused in one wording by all three models —
# that much the migration runner suite already holds. What it reads afterwards is
# the ledger, the presentation, and the rows of the sources, none of which is
# storage. `merge_tables` creates its target before it injects anything and
# `split_table` creates a fibre before it fills one, so "refused before anything
# is written" is a claim about the objects the database holds, and this is where
# it is checked.
class DBConformanceRefusedStepStorageTest < Minitest::Test
  SPLIT = Sodalite::DB.history(
    [:create_table, :animals, { id: :integer, name: :string, species: :string }],
    [:split_table, :animals, :species, { 'cats' => :cats }]
  )

  MERGE = Sodalite::DB.history(
    [:create_table, :cats, { id: :integer, name: :string }],
    [:create_table, :dogs, { id: :integer, name: :string }],
    [:merge_tables, %i[cats dogs], :animals, :species]
  )

  # The model, and a way to ask what the storage is holding. The two answers are
  # different questions, and after a step that was refused only the second one is
  # evidence.
  Runner = Struct.new(:model, :objects)

  def runners(history, count)
    skip 'sqlite3 unavailable' unless EDGES_SQLITE

    adapter = EdgesAdapter.new
    db = Sequel.sqlite
    memory = Sodalite::DB.memory(EDGES_EMPTY)
    prefix = Sodalite::DB.history(*history.plan.order.first(count))
    [Runner.new(memory, -> { memory.instance_variable_get(:@store).keys }),
     Runner.new(Sodalite::DB.sql(EDGES_EMPTY, adapter), -> { adapter.tables }),
     Runner.new(Sodalite::DB.sequel(EDGES_EMPTY, db), -> { db.tables })].each { |runner| runner.model.migrate!(prefix) }
  end

  def test_a_refused_split_leaves_none_of_the_fibres_it_would_have_made
    runners(SPLIT, 1).each do |runner|
      runner.model.insert(:animals, { id: 1, name: 'mi', species: 'cats' })
      runner.model.insert(:animals, { id: 2, name: 'pochi', species: 'dogs' })
      assert_raises(Sodalite::DB::MigrationError, runner.model.class.name) { runner.model.migrate!(SPLIT) }

      refute_includes runner.objects.call, :cats, runner.model.class.name
      assert_includes runner.objects.call, :animals, runner.model.class.name
      assert_equal %i[animals], runner.model.schema.names, runner.model.class.name
    end
  end

  def test_a_refused_merge_leaves_none_of_the_coproduct_it_would_have_made
    runners(MERGE, 2).each do |runner|
      runner.model.insert(:cats, { id: 1, name: 'mi' })
      runner.model.insert(:dogs, { id: 1, name: 'pochi' })
      assert_raises(Sodalite::DB::MigrationError, runner.model.class.name) { runner.model.migrate!(MERGE) }

      refute_includes runner.objects.call, :animals, runner.model.class.name
      assert_includes runner.objects.call, :cats, runner.model.class.name
      assert_includes runner.objects.call, :dogs, runner.model.class.name
    end
  end
end
