# frozen_string_literal: true

module DeadGem
  class Transliterator
    def transliterate(value)
      value.encode("ASCII", invalid: :replace, undef: :replace, replace: "")
    end
  end
end
