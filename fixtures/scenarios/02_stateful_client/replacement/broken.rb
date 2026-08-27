# frozen_string_literal: true

module Replacement
  class Disconnected < StandardError; end

  class Session
    attr_reader :phase

    def initialize = @phase = :down
    def start = @phase = :ready
    def query = :data
    def shutdown = nil
  end
end
