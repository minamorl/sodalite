# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# What an operation would dirty, given only the value it was about to be
# performed with.
#
# The write half of the invalidation calculus. Its reason for existing is one
# property — if a write's addresses are disjoint from a query's reads, that write
# cannot change that query's answer — and what is checked here is the half that
# property rests on: the addresses coming back are exactly the places the
# operation touches. Too few and the property lies; too many and it is true and
# useless, because everything is then a possible invalidation of everything.
WRITES_SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string },
  posts: { id: :integer, title: :string, body: :string, views: :integer, author: Sodalite::DB.fk(:users) }
)

class DBWritesTest < Minitest::Test
  DB = Sodalite::DB

  # A set of addresses in the one order it has, so a failure reads as a set of
  # places rather than as whatever order they were accumulated in.
  def places(tag, payload)
    DB.writes(tag, payload).sort.map(&:to_s)
  end

  # --- reading dirties nothing -----------------------------------------------

  def test_a_select_dirties_nothing
    assert_empty places(DB::SELECT, WRITES_SCHEMA[:posts].where(:title, 'first'))
  end

  # The empty set, not a refusal, however far the arrow travelled: composing,
  # folding, and presenting are all still reading.
  def test_a_select_dirties_nothing_however_the_arrow_was_built
    folded = WRITES_SCHEMA[:posts].follow(:author).group(:city).count(:many)

    assert_empty places(DB::SELECT, folded)
  end

  # --- an insert changes which elements exist, and nothing else ---------------

  # The row names three fields and the answer names none of them. An insert
  # cannot change where a map sends an element that was already there, and every
  # arrow over an object reads that object's elements, so this is both sufficient
  # and tighter than naming the fields as well.
  def test_an_insert_dirties_which_elements_the_object_has
    assert_equal ['posts'], places(DB::INSERT, [:posts, { id: 1, title: 'first', author: 2 }])
  end

  # --- an update changes where a map sends them, and nothing else -------------

  def test_an_update_dirties_the_field_it_names
    assert_equal ['posts.title'], places(DB::UPDATE, [WRITES_SCHEMA[:posts], { title: 'second' }])
  end

  def test_an_update_dirties_every_field_it_names
    changes = { title: 'second', body: 'text' }

    assert_equal ['posts.body', 'posts.title'], places(DB::UPDATE, [WRITES_SCHEMA[:posts], changes])
  end

  # `{ 'title' => 'second' }`, `{ title: DB.set('second') }`, and
  # `{ title: 'second' }` are one change, and `Change.ordered` is the one place
  # that says so. Reading the Hash a second way here would let the set of places
  # disagree with the statement the models are about to emit.
  def test_an_update_reads_a_changes_hash_the_way_the_models_do
    guarded = WRITES_SCHEMA[:posts].where(:body, 'text')

    assert_equal ['posts.title'], places(DB::UPDATE, [guarded, { 'title' => 'second' }])
    assert_equal ['posts.title'], places(DB::UPDATE, [guarded, { title: DB.set('second') }])
    assert_equal ['posts.views'], places(DB::UPDATE, [guarded, { views: DB.add(1) }])
  end

  # The case the whole design exists for. An update cannot make an element appear
  # or disappear, so it never dirties the object — which is what leaves a query
  # that only reads `posts.id` alone.
  def test_an_update_never_says_which_elements_exist
    [{ title: 'second' }, { title: 'second', body: 'text' }, { views: DB.add(1) },
     { author: 3 }].each do |changes|
      addresses = DB.writes(DB::UPDATE, [WRITES_SCHEMA[:posts], changes])

      assert_empty addresses.select(&:elements?).map(&:to_s), changes.inspect
    end
  end

  # A foreign key is a map out of the object like any other, so reassigning it
  # dirties `posts.author` and not the object it points at: the element still
  # exists on both sides, and only where the map sends it has moved.
  def test_an_update_of_a_foreign_key_dirties_the_map_and_not_its_target
    assert_equal ['posts.author'], places(DB::UPDATE, [WRITES_SCHEMA[:posts], { author: 3 }])
  end

  # Composition moved the carrier, so this changes rows of users. The addresses
  # are the codomain's fields, for the same reason the caller had to name the
  # codomain before it was allowed to write at all.
  def test_an_update_through_a_composition_addresses_the_codomain
    composed = WRITES_SCHEMA[:posts].follow(:author)
    changes = { city: 'osaka' }

    assert_same composed, composed.updatable!(changes, confirm_carrier: :users)
    assert_equal ['users.city'], places(DB::UPDATE, [composed, changes])
  end

  # --- a delete changes which elements exist ----------------------------------

  def test_a_delete_dirties_which_elements_the_carrier_has
    assert_equal ['posts'], places(DB::DELETE, WRITES_SCHEMA[:posts].where(:title, 'first'))
  end

  # The carrier, not the root: a delete through a composition removes elements of
  # the codomain, which is exactly what `deletable!` made the caller say.
  def test_a_delete_through_a_composition_addresses_the_codomain
    composed = WRITES_SCHEMA[:posts].follow(:author)

    assert_same composed, composed.deletable!(confirm_carrier: :users)
    assert_equal ['users'], places(DB::DELETE, composed)
  end

  # --- what cannot be answered from the value ---------------------------------

  # Not the empty set. The empty set is a claim that the scope dirties nothing,
  # which is the one answer guaranteed to be wrong.
  def test_a_scope_is_refused_rather_than_answered
    workflow = DB.atomically(:sell, Berylx::Task[:done] { |lay| lay })
    refused = assert_raises(DB::WritesError) { DB.writes(DB::ATOMICALLY, [workflow, {}]) }

    assert_match(/a scope does not say what it writes/, refused.message)
    assert_match(/not decidable from the value/, refused.message)
    assert_match(/union the writes of the operations composed inside it/, refused.message)
    assert_match(/certainly wrong/, refused.message)
  end

  def test_a_tag_that_is_not_an_operation_is_refused
    refused = assert_raises(DB::WritesError) { DB.writes(:charge_a_card, nil) }

    assert_match(/:charge_a_card is not one of the five operations/, refused.message)
    assert_match(/nothing is known about what it dirties/, refused.message)
    assert_match(/sodalite_db_select/, refused.message)
  end
end
