# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

begin
  require 'sqlite3'
  require 'sequel'
  LEDGER_SQLITE = true
rescue LoadError
  LEDGER_SQLITE = false
end

class DBLedgerTest < Minitest::Test
  EMPTY = Sodalite::DB::Schema.new({})

  def test_declaration_order_does_not_reapply_steps
    first = Sodalite::DB.history(
      [:create_table, :users, { id: :integer }],
      [:create_table, :posts, { id: :integer }]
    )
    reordered = Sodalite::DB.history(*first.steps.reverse)

    models.each do |model|
      model.migrate!(first)
      before = model.applied
      model.migrate!(reordered)

      assert_equal before, model.applied
    end
  end

  def test_an_edited_step_has_a_new_content_address
    original = Sodalite::DB.history([:create_table, :users, { id: :integer }])
    edited = Sodalite::DB.history([:create_table, :users, { id: :integer, name: :string }])
    model = Sodalite::DB.memory(EMPTY).migrate!(original)

    model.migrate!(edited)

    assert_includes model.applied, original.steps.first.fingerprint
    assert_includes model.applied, edited.steps.first.fingerprint
  end

  def test_every_ledger_is_keyed_by_fingerprint
    history = Sodalite::DB.history([:create_table, :users, { id: :integer }])

    models.each do |model|
      model.migrate!(history)

      assert_equal({ history.steps.first.fingerprint => history.steps.first.to_s }, model.applied)
    end
  end

  def test_a_held_lock_refuses_another_migration
    history = Sodalite::DB.history([:create_table, :users, { id: :integer }])

    models.each do |model|
      assert model.claim_lock('held')
      error = assert_raises(Sodalite::DB::MigrationError) { model.migrate!(history) }
      assert_match(/another migration/, error.message)
      model.release_lock('held')
    end
  end

  def test_rollback_restores_presentation_and_rows
    history = Sodalite::DB.history(
      [:create_table, :users, { id: :integer }],
      [:add_attribute, :users, :name, :string, 'unknown']
    )

    models.each do |model|
      model.migrate!(Sodalite::DB.history(history.steps.first))
      model.insert(:users, { id: 1 })
      model.migrate!(history).rollback!(history, to: 1)

      assert_equal %i[id], model.schema.table(:users).fields
      rows = if model.is_a?(Sodalite::DB::Memory)
               model.rows(:users)
             else
               model.select(model.schema[:users]).rows
             end

      assert_equal [{ id: 1 }], rows
    end
  end

  def test_irreversible_rollback_fails_before_touching_rows
    history = Sodalite::DB.history(
      [:create_table, :users, { id: :integer, name: :string }],
      %i[drop_attribute users name]
    )
    model = Sodalite::DB.memory(EMPTY).migrate!(Sodalite::DB.history(history.steps.first))
    model.insert(:users, { id: 1, name: 'mina' })
    model.migrate!(history)
    before = model.rows(:users)

    assert_raises(Sodalite::DB::MigrationError) { model.rollback!(history, to: 0) }
    assert_equal before, model.rows(:users)
  end

  def test_verify_allows_contract_but_rejects_expansion_and_newer_ledger
    create = [:create_table, :users, { id: :integer, name: :string }]
    contract = Sodalite::DB.history(create, %i[drop_attribute users name])
    model = Sodalite::DB.memory(EMPTY).migrate!(Sodalite::DB.history(create))

    assert_same model, model.verify!(contract)

    expansion = Sodalite::DB.history(create, [:add_attribute, :users, :city, :string, 'unknown'])
    assert_raises(Sodalite::DB::MigrationError) { model.verify!(expansion) }

    model.migrate!(contract)
    assert_raises(Sodalite::DB::MigrationError) do
      model.verify!(Sodalite::DB.history(create))
    end
  end

  private

  def models
    skip 'sqlite3 unavailable' unless LEDGER_SQLITE

    [Sodalite::DB.memory(EMPTY),
     Sodalite::DB.sql(EMPTY, Adapter.new),
     Sodalite::DB.sequel(EMPTY, Sequel.sqlite)]
  end

  class Adapter
    def initialize
      @db = SQLite3::Database.new(':memory:')
    end

    def execute(sql, binds)
      @db.execute(sql, binds)
    end
  end
end
