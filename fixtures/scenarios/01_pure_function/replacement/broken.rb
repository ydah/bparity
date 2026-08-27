# frozen_string_literal: true

module Replacement
  class Transliterator
    def transliterate(value) = value
  end

  module Slugs
    module_function

    def generate(text:)
      Transliterator.new.transliterate(text).downcase.gsub(/[^a-z0-9]+/, "-")
    end
  end
end
