# frozen_string_literal: true

module Replacement
  module Identity
    module_function

    def display(value:) = value || "anonymous"
  end
end
