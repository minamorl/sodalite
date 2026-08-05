# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# A foreign key column carries the target's key, so its type is the target's key
# type. Calling it an integer regardless is not a cosmetic mismatch with the
# DDL: the row schema validates against that type, so the lie is inside the
# validation boundary. It is resolved once, where the objects are wired up.
class DBSchemaColumnTypeTest < Minitest::Test
  STRING_KEYED = Sodalite::DB.schema(
    users: { id: :string, name: :string },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  INTEGER_KEYED = Sodalite::DB.schema(
    users: { id: :integer, name: :string },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  def test_a_foreign_key_has_the_type_of_the_key_it_carries
    posts = STRING_KEYED.table(:posts)

    assert_equal :string, posts.column_type(:author)
    assert_equal :string, posts.row_schema.spec[:author]
  end

  def test_the_row_type_rejects_a_row_that_does_not_carry_that_key
    posts = STRING_KEYED.table(:posts)

    refute_predicate posts.row_schema.load({ 'id' => 1, 'title' => 'hi', 'author' => 7 }), :ok?
    assert_predicate posts.row_schema.load({ 'id' => 1, 'title' => 'hi', 'author' => 'mina' }), :ok?
  end

  # The boundary the type was inside all along: a model validates a row against
  # the row type before storing it, so an unresolved foreign key was a lie the
  # validation then checked against.
  def test_a_model_refuses_a_row_whose_foreign_key_is_not_the_key_it_carries
    model = Sodalite::DB.memory(STRING_KEYED, users: [{ id: 'mina', name: 'mina' }])

    error = assert_raises(Sodalite::DB::SchemaError) { model.insert(:posts, { id: 1, title: 'hi', author: 7 }) }

    assert_match(%r{/author: expected string}, error.message)
    assert_equal 2, model.insert(:posts, { id: 2, title: 'hi', author: 'mina' })
    assert_empty model.violations
  end

  def test_a_key_that_is_an_integer_still_resolves_to_integer
    posts = INTEGER_KEYED.table(:posts)

    assert_equal :integer, posts.column_type(:author)
    assert_equal :integer, posts.row_schema.spec[:author]
    assert_predicate posts.row_schema.load({ 'id' => 1, 'title' => 'hi', 'author' => 7 }), :ok?
  end

  def test_an_attribute_keeps_the_type_it_was_declared_with
    assert_equal :string, STRING_KEYED.table(:posts).column_type(:title)
    assert_equal :integer, STRING_KEYED.table(:posts).column_type(:id)
    assert_equal :string, STRING_KEYED.table(:users).column_type(:id)
  end

  # `attributes` means morphisms into leaf objects. A foreign key having a type
  # does not make it one of those; it still goes to an object of the category.
  def test_a_foreign_key_is_a_morphism_not_an_attribute
    posts = STRING_KEYED.table(:posts)

    refute_includes posts.attributes.keys, :author
    assert_equal({ author: :users }, posts.foreign_keys)
    assert_equal %i[id title author], posts.fields
  end

  # The presentation is complete before any object is built from it, so a
  # morphism may point at its own object.
  def test_a_self_referencing_foreign_key_resolves
    schema = Sodalite::DB.schema(employees: { id: :integer, manager: Sodalite::DB.fk(:employees) })

    assert_equal :integer, schema.table(:employees).column_type(:manager)
  end

  # ...or at an object declared after it.
  def test_a_forward_referencing_foreign_key_resolves
    schema = Sodalite::DB.schema(
      posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) },
      users: { id: :string, name: :string }
    )

    assert_equal :string, schema.table(:posts).column_type(:author)
  end

  def test_a_foreign_key_to_an_unknown_table_is_a_build_error
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(posts: { id: :integer, author: Sodalite::DB.fk(:nobody) })
    end

    assert_match(/points at unknown table :nobody/, error.message)
  end

  # There is no key type to carry, so the morphism has no type either — and the
  # error names both ends of it rather than one.
  def test_a_foreign_key_into_a_table_with_no_key_is_a_build_error
    error = assert_raises(Sodalite::DB::SchemaError) do
      Sodalite::DB.schema(users: { name: :string },
                          posts: { id: :integer, author: Sodalite::DB.fk(:users) })
    end

    assert_equal 'posts.author points at users, which has no key :id', error.message
  end

  def test_a_table_with_no_key_is_still_a_build_error
    error = assert_raises(Sodalite::DB::SchemaError) { Sodalite::DB.schema(users: { name: :string }) }

    assert_equal 'users has no key :id', error.message
  end

  # The key is `id` by construction. It used to be a keyword argument that
  # nothing could reach, which is a worse state than either fixing it or
  # threading it through.
  def test_the_key_is_a_constant_of_the_object
    assert_equal :id, Sodalite::DB::Table::KEY
    assert_equal :id, STRING_KEYED.table(:posts).key
  end
end

# Every model reports a dangling foreign key with the same sentence, so the
# sentence lives in one place. Referential integrity stays a reportable property
# of an instance rather than an invariant checked on write, which is why this is
# a message and not a guard.
class DBSchemaDanglingMessageTest < Minitest::Test
  SCHEMA = Sodalite::DB.schema(
    users: { id: :integer, name: :string },
    posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
  )

  def test_the_schema_spells_a_dangling_key
    assert_equal 'posts.author=99 has no users', SCHEMA.dangling_message(:posts, :author, 99, :users)
  end

  def test_it_is_the_sentence_a_model_reports
    model = Sodalite::DB.memory(SCHEMA, users: [], posts: [{ id: 10, title: 'hi', author: 99 }])

    assert_equal [SCHEMA.dangling_message(:posts, :author, 99, :users)], model.violations
  end
end
