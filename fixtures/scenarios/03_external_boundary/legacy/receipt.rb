# frozen_string_literal: true

require_relative "dead_formatter"

module Legacy
  class Receipt
    def print(cents)
      "Total: #{RetiredFormatter::Money.new.format(cents)}"
    end
  end
end
