# frozen_string_literal: true

module Legacy
  class NotConnectedError < StandardError; end

  class Client
    attr_reader :status

    def initialize
      @status = :closed
    end

    def connect
      @status = :open
      true
    end

    def fetch
      raise NotConnectedError, "client is closed" unless status == :open

      :data
    end

    def close
      @status = :closed
      nil
    end
  end
end
