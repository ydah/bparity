# frozen_string_literal: true

require "open3"

module Bparity
  module Adequacy
    class MutantBridge
      SCORE = /Mutation coverage:\s*([\d.]+)%/

      def available?
        _output, _error, status = Open3.capture3("bundle", "exec", "mutant", "--version")
        status.success?
      rescue Errno::ENOENT
        false
      end

      def run
        return { "status" => "skipped", "reason" => "mutant is not installed" } unless available?

        output, error, status = Open3.capture3("bundle", "exec", "mutant", "run")
        match = output.match(SCORE)
        score = match[1].to_f if match
        { "status" => status.success? ? "completed" : "failed", "score" => score,
          "output" => output, "error" => error }
      end
    end

    module CoverageReconciler
      module_function

      def call(gaps:, surviving_mutants: [])
        risks = gaps.map { |gap| "Legacy gap: #{gap['location'] || gap['note'] || gap['kind']}" }
        risks + surviving_mutants.map { |mutant| "Unconstrained replacement behavior: #{mutant}" }
      end
    end

    class Analyzer
      def initialize(bundle:, results:, mutation: nil)
        @bundle = bundle
        @results = results
        @mutation = mutation || { "status" => "skipped", "reason" => "not requested" }
      end

      def call
        examples = @bundle.fetch("subjects").flat_map { |subject| subject.fetch("operations") }
                          .flat_map { |operation| operation.fetch("examples") }
        evaluated = @results.length
        {
          "specification_coverage" => ratio(evaluated, examples.length),
          "recorded_examples" => examples.length,
          "generated_checks" => generated_checks,
          "formal_assurance" => Reporting::AssuranceMatrix.new(@bundle).to_h,
          "constraint_strength" => @mutation,
          "residual_risks" => CoverageReconciler.call(gaps: @bundle.fetch("gaps", []),
                                                      surviving_mutants: mutation_risks),
          "waiver_count" => @results.count { |result| result.status == :waived }
        }
      end

      private

      def generated_checks
        @bundle.fetch("subjects").sum do |subject|
          subject.fetch("operations").sum { |operation| operation.fetch("invariants", []).length }
        end
      end

      def ratio(numerator, denominator) = denominator.zero? ? 1.0 : (numerator.to_f / denominator).round(4)

      def mutation_risks
        score = @mutation["score"]
        return [] unless score && score < 100

        ["mutation score #{score}% (inspect the mutant output for survivors)"]
      end
    end
  end
end
