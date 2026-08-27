# frozen_string_literal: true

module Bparity
  module Formal
    class Scope
      attr_reader :size, :depth, :cases, :exhaustive, :timebox

      def initialize(size:, depth:, cases:, exhaustive:, timebox: nil)
        @size = size
        @depth = depth
        @cases = cases
        @exhaustive = exhaustive
        @timebox = timebox
      end

      def to_h
        { "size" => size, "depth" => depth, "cases" => cases, "exhaustive" => exhaustive,
          "timebox_seconds" => timebox }
      end
    end

    class Result
      VERDICTS = %i[no_difference_found difference_found inconclusive].freeze

      attr_reader :level, :verdict, :scope, :assumptions, :out_of_scope, :counterexample, :details

      def initialize(level:, verdict:, scope:, assumptions:, out_of_scope:, counterexample: nil, details: {})
        raise ConfigurationError, "A formal result requires a scope." unless scope
        raise ConfigurationError, "A formal result requires verification assumptions." if assumptions.nil?
        raise ConfigurationError, "Invalid formal verdict: #{verdict}." unless VERDICTS.include?(verdict)

        @level = level.to_s.upcase
        @verdict = verdict
        @scope = scope
        @assumptions = assumptions
        @out_of_scope = out_of_scope
        @counterexample = counterexample
        @details = details
      end

      def to_h
        { "level" => level, "verdict" => verdict.to_s, "scope" => scope.to_h,
          "assumptions" => assumptions.map(&:to_s), "out_of_scope" => out_of_scope,
          "counterexample" => counterexample, "details" => details }
      end

      def success? = verdict == :no_difference_found
    end
  end
end
