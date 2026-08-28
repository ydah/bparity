# frozen_string_literal: true

require_relative "dead_identity"

module Legacy
  class Identity
    def label(name) = name || RetiredIdentity.guest_name
  end
end
