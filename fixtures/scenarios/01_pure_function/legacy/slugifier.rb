# frozen_string_literal: true

require_relative "dead_gem"

module Legacy
  class Slugifier
    def initialize
      @transliterator = DeadGem::Transliterator.new
    end

    def call(value)
      raise ArgumentError, "blank" if value.nil? || value.strip.empty?

      @transliterator.transliterate(value).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|\-\z/, "")
    end
  end
end
