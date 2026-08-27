# frozen_string_literal: true

module Bparity
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvalidBundleError < Error; end
  class VerificationError < Error; end
end
