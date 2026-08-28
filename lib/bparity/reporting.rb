# frozen_string_literal: true

require "cgi"
require "json"

module Bparity
  module Reporting
    class AssuranceMatrix
      PROVENANCE = %w[A B C D].freeze
      FORMAL = %w[F0 F1 F2 F3 F4].freeze

      def initialize(bundle)
        @bundle = bundle
      end

      def to_h
        matrix = PROVENANCE.to_h { |provenance| [provenance, FORMAL.to_h { |formal| [formal, 0] }] }
        items.each do |item|
          provenance = item.fetch("provenance_level", "D")
          formal = item.fetch("formal_level", "F0")
          matrix.fetch(provenance).fetch(formal)
          matrix[provenance][formal] += 1
        end
        matrix
      end

      private

      def items
        @bundle.fetch("subjects", []).flat_map { |subject| subject.fetch("operations", []) }
               .flat_map { |operation| operation.fetch("examples", []) + operation.fetch("invariants", []) }
      end
    end

    class Reporter
      def initialize(results, bundle: nil)
        @results = results
        @bundle = bundle
      end

      def summary
        counts = @results.group_by(&:status).transform_values(&:count)
        { "total" => @results.count, "pass" => counts.fetch(:pass, 0), "fail" => counts.fetch(:fail, 0),
          "waived" => counts.fetch(:waived, 0), "results" => @results.map(&:to_h),
          "assumptions" => @bundle&.fetch("verification_assumptions", []),
          "assurance_matrix" => @bundle ? AssuranceMatrix.new(@bundle).to_h : {},
          "five_point_assessment" => @bundle ? Adequacy::Analyzer.new(bundle: @bundle, results: @results).call : {} }
      end

      def json = JSON.pretty_generate(summary)

      def markdown
        data = summary
        lines = ["# bparity conformance report", "",
                 "Total: #{data['total']} | PASS: #{data['pass']} | " \
                 "FAIL: #{data['fail']} | WAIVED: #{data['waived']}", ""]
        @results.each do |result|
          lines << "- **#{result.status.to_s.upcase}** `#{result.id}` #{result.description}"
          result.differences.each do |difference|
            lines << "  - `#{difference['path']}` expected `#{difference['expected'].inspect}`, " \
                     "got `#{difference['actual'].inspect}`"
          end
        end
        assessment = data.fetch("five_point_assessment")
        unless assessment.empty?
          lines.push("", "## Five-point assessment", "",
                     "1. Specification coverage: #{assessment.fetch('specification_coverage')}",
                     "2. Generated checks: #{assessment.fetch('generated_checks')}",
                     "3. Formal assurance: #{JSON.generate(assessment.fetch('formal_assurance'))}",
                     "4. Constraint strength: #{assessment.fetch('constraint_strength').fetch('status')}",
                     "5. Residual risks: #{residual_risks(assessment)}")
        end
        lines.join("\n")
      end

      def junit
        failures = @results.count { |result| result.status == :fail }
        cases = @results.map do |result|
          failure = if result.status == :fail
                      details = CGI.escapeHTML(JSON.generate(result.differences))
                      "<failure message=\"Behavior differs\">#{details}</failure>"
                    end
          "<testcase name=\"#{CGI.escapeHTML(result.id)}\">#{failure}</testcase>"
        end.join
        header = %(<?xml version="1.0" encoding="UTF-8"?>)
        suite = %(<testsuite tests="#{@results.length}" failures="#{failures}">#{cases}</testsuite>)
        header + suite
      end

      def html
        rows = @results.map do |result|
          details = CGI.escapeHTML(JSON.pretty_generate(result.differences))
          "<tr><td>#{result.status.to_s.upcase}</td><td>#{CGI.escapeHTML(result.id)}</td>" \
            "<td><pre>#{details}</pre></td></tr>"
        end.join
        data = summary
        matrix = matrix_html(data.fetch("assurance_matrix"))
        assessment = CGI.escapeHTML(JSON.pretty_generate(data.fetch("five_point_assessment")))
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>bparity report</title>" \
          "<h1>bparity conformance report</h1>#{matrix}<h2>Five-point assessment</h2><pre>#{assessment}</pre>" \
          "<table><thead><tr><th>Status</th><th>ID</th><th>Details</th></tr>" \
          "</thead><tbody>#{rows}</tbody></table></html>"
      end

      private

      def matrix_html(matrix)
        header = "<tr><th>Provenance</th>#{AssuranceMatrix::FORMAL.map { |level| "<th>#{level}</th>" }.join}</tr>"
        rows = matrix.map do |provenance, levels|
          "<tr><th>#{provenance}</th>#{levels.values.map { |count| "<td>#{count}</td>" }.join}</tr>"
        end.join
        "<h2>Provenance × formal assurance</h2><table>#{header}#{rows}</table>"
      end

      def residual_risks(assessment)
        risks = assessment.fetch("residual_risks")
        risks.empty? ? "none identified" : risks.first(5).join("; ")
      end
    end
  end
end
