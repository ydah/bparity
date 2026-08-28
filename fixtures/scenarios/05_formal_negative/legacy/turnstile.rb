# frozen_string_literal: true

require_relative "dead_lock"

module Legacy
  class PureToken
    def token(value) = value + 1
  end

  class Turnstile
    attr_reader :locked

    def initialize = @locked = RetiredLock::DEFAULT_LOCKED
    def unlock = (@locked = false; :ok)
    def lock = (@locked = true; :ok)

    def enter
      return :denied if locked

      @locked = true
      :entered
    end
  end
end
