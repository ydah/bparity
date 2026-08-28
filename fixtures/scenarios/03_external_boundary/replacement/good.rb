# frozen_string_literal: true

module Replacement
  class Currency
    def render(cents) = "$#{cents / 100}"
  end

  class ReceiptView
    def render(total:) = "Total: #{Currency.new.render(total)}"
  end
end
