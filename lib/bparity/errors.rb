# frozen_string_literal: true

module Bparity
  def self.exception_message(error)
    error.respond_to?(:original_message) ? error.original_message : error.message
  end

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidBundleError < Error; end
  class VerificationError < Error; end
end
