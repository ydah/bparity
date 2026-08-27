# frozen_string_literal: true

module Replacement
  class Transliterator
    def transliterate(value)
      value.encode("ASCII", invalid: :replace, undef: :replace, replace: "")
    end
  end

  module Slugs
    module_function

    def generate(text:)
      raise ArgumentError, "blank" if text.nil? || text.strip.empty?

      Transliterator.new.transliterate(text).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|\-\z/, "")
    end
  end
end
