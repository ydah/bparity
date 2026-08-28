# frozen_string_literal: true

require_relative "bparity/version"
require_relative "bparity/errors"
require_relative "bparity/boundary"
require_relative "bparity/recording"
require_relative "bparity/corpus"
require_relative "bparity/adapter"
require_relative "bparity/spec_bundle"
require_relative "bparity/synthesis"
require_relative "bparity/verification"
require_relative "bparity/reporting"
require_relative "bparity/formal"
require_relative "bparity/adequacy"

module Bparity
  class << self
    attr_reader :boundary_definition, :adapter_definition

    # Defines the observable legacy API.
    def boundary(&block)
      @boundary_definition = Boundary::Definition.new.tap { |definition| definition.instance_eval(&block) }
    end

    # Maps a specification bundle onto a replacement API.
    def adapter(spec: nil, &block)
      @adapter_definition = Adapter::Definition.new(spec: spec).tap { |definition| definition.instance_eval(&block) }
    end

    def reset!
      @boundary_definition = @adapter_definition = nil
    end

    def constantize(name)
      name.split("::").reject(&:empty?).inject(Object) { |scope, part| scope.const_get(part, false) }
    rescue NameError
      raise ConfigurationError, "Cannot find #{name}. Require the target implementation first."
    end
  end
end

BehaviorParity = Bparity unless defined?(BehaviorParity)
