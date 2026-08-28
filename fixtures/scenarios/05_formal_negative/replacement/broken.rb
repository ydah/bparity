# frozen_string_literal: true

module Replacement
  module PureTokenService
    module_function

    def shift(value) = value + 1
  end

  class Gate
    attr_reader :phase

    def initialize = @phase = :secured
    def release = (@phase = :open; :ok)
    def secure = (@phase = :secured; :ok)
    def pass = phase == :secured ? :denied : :entered
  end
end
