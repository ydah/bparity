# frozen_string_literal: true

module RetiredFormatter
  class Money
    def format(cents) = "$#{cents / 100}"
  end
end
