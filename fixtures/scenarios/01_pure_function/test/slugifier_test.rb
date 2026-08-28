# frozen_string_literal: true

require "minitest/test"
require_relative "../legacy/slugifier"

class SlugifierTest < Minitest::Test
  def test_normalizes_a_title
    assert_equal "hello-world", Legacy::Slugifier.new.call("Hello World")
  end
end
