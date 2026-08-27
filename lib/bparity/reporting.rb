# frozen_string_literal: true

require "cgi"
require "json"

module Bparity
  module Reporting
    class Reporter
      def initialize(results, bundle: nil)
        @results = results
        @bundle = bundle
      end

      def summary
        counts = @results.group_by(&:status).transform_values(&:count)
        { "total" => @results.count, "pass" => counts.fetch(:pass, 0), "fail" => counts.fetch(:fail, 0),
          "waived" => counts.fetch(:waived, 0), "results" => @results.map(&:to_h),
          "assumptions" => @bundle&.fetch("verification_assumptions", []) }
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
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>bparity report</title>" \
          "<h1>bparity conformance report</h1><table><thead><tr><th>Status</th><th>ID</th><th>Details</th></tr>" \
          "</thead><tbody>#{rows}</tbody></table></html>"
      end
    end
  end
end
