# frozen_string_literal: true

module Replacement
  class Disconnected < StandardError; end

  class Session
    attr_reader :phase

    def initialize
      @phase = :down
    end

    def start = @phase = :ready

    def query
      raise Disconnected, "client is closed" unless phase == :ready

      :data
    end

    def shutdown = @phase = :down
  end
end
