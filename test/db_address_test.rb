# frozen_string_literal: true

require 'test_helper'
require 'sodalite/db'

# The vocabulary the invalidation calculus is written in. It is a value, so what
# there is to check is that it behaves like one — two spellings of the same
# place are the same key, and a set of them has one rendering.
class DBAddressTest < Minitest::Test
  Address = Sodalite::DB::Address

  def test_the_same_place_is_the_same_key_however_it_was_spelled
    assert_equal Address.elements(:posts), Address.elements('posts')
    assert_equal Address.field(:posts, :title), Address.field('posts', 'title')
    assert_equal 1, Set[Address.field(:posts, :title), Address.field('posts', 'title')].size
  end

  # The split is the whole point, so the two kinds over one object are two
  # addresses and not one.
  def test_which_elements_exist_is_not_where_a_map_sends_them
    refute_equal Address.elements(:posts), Address.field(:posts, :title)
    assert_predicate Address.elements(:posts), :elements?
    refute_predicate Address.field(:posts, :title), :elements?
  end

  def test_a_map_out_of_one_object_is_not_the_same_map_out_of_another
    refute_equal Address.field(:posts, :author), Address.field(:comments, :author)
  end

  # A set of addresses is compared in test failures and read by a person, so it
  # has one order rather than whatever order it was accumulated in.
  def test_a_set_of_addresses_has_one_rendering
    addresses = [Address.field(:users, :name), Address.elements(:posts),
                 Address.field(:posts, :title), Address.elements(:users)]

    assert_equal ['posts', 'posts.title', 'users', 'users.name'], addresses.sort.map(&:to_s)
  end

  def test_an_address_says_where_it_points_when_it_is_printed
    assert_equal 'posts', Address.elements(:posts).to_s
    assert_equal 'posts.title', Address.field(:posts, :title).to_s
    assert_equal 'posts.title', Address.field(:posts, :title).inspect
  end

  def test_an_address_does_not_order_itself_against_something_that_is_not_one
    assert_nil(Address.elements(:posts) <=> :posts)
  end
end
