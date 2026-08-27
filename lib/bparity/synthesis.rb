# frozen_string_literal: true

require "prism"

module Bparity
  module Synthesis
    class StaticExtractor
      SPEC_CALLS = %i[describe context it specify].freeze
      ASSERTIONS = %i[eq eql equal raise_error assert assert_equal assert_raises].freeze

      def extract_tests(paths)
        Array(paths).flat_map { |path| extract_test_file(path) }
      end

      def extract_source(paths)
        Array(paths).flat_map do |path|
          result = Prism.parse_file(path)
          raise Error, "Cannot parse #{path}. Fix its Ruby syntax and try again." unless result.success?

          nodes(result.value).filter_map do |node|
            next unless node.type == :call_node && node.name == :raise

            { "kind" => "guard", "location" => "#{path}:#{node.location.start_line}",
              "source" => node.location.slice }
          end
        end
      end

      private

      def extract_test_file(path)
        result = Prism.parse_file(path)
        raise Error, "Cannot parse #{path}. Fix its Ruby syntax and try again." unless result.success?

        extract_spec_nodes(result.value, path, [])
      end

      def extract_spec_nodes(node, path, context)
        return [] unless node

        if node.type == :call_node && SPEC_CALLS.include?(node.name) && node.block
          description = literal(node.arguments&.arguments&.first) || node.name.to_s
          nested = context + [description]
          return [spec_item(node, path, nested)] if %i[it specify].include?(node.name)

          return node.block.body ? extract_spec_nodes(node.block.body, path, nested) : []
        end
        node.compact_child_nodes.flat_map { |child| extract_spec_nodes(child, path, context) }
      end

      def spec_item(node, path, context)
        assertions = nodes(node.block.body).filter_map do |child|
          child.name.to_s if child.type == :call_node && ASSERTIONS.include?(child.name)
        end.uniq
        { "description" => context.join(" "), "location" => "#{path}:#{node.location.start_line}",
          "assertions" => assertions }
      end

      def nodes(root, &block)
        return enum_for(__method__, root) unless block_given?

        yield root
        root.compact_child_nodes.each { |child| nodes(child, &block) }
      end

      def literal(node)
        return unless node
        return node.unescaped if node.respond_to?(:unescaped)
        return node.value.to_s if node.respond_to?(:value)

        node.location.slice
      end
    end

    class Synthesizer
      ASSUMPTIONS = [
        { "id" => "H1", "name" => "world_freeze", "enforced_by" => "runtime monitor" },
        { "id" => "H3", "name" => "no_eval", "enforced_by" => "Prism static detection" },
        { "id" => "H7", "name" => "single_thread", "enforced_by" => "declaration only" }
      ].freeze

      def initialize(records:, static_examples: [], source_facts: [])
        @records = records
        @static_examples = static_examples
        @source_facts = source_facts
      end

      def call
        {
          "spec_bundle_version" => SpecBundle::VERSION,
          "generated_at" => Time.now.utc.iso8601,
          "conformance_mode" => "refinement",
          "verification_assumptions" => ASSUMPTIONS,
          "subjects" => subjects,
          "gaps" => @source_facts.map { |fact| fact.merge("kind" => "static_only") },
          "waivers" => []
        }
      end

      private

      def subjects
        @records.group_by { |record| record["subject"] }.map do |name, records|
          { "name" => short_name(name), "old_class" => name, "operations" => operations(records) }
        end
      end

      def operations(records)
        records.group_by { |record| record["operation"] }.map do |name, calls|
          { "name" => name, "examples" => calls.map { |call| example(call) } }
        end
      end

      def example(call)
        provenance = call["provenance"] || {}
        static = @static_examples.find { |item| item["description"] == provenance["description"] }
        {
          "id" => call["id"], "provenance_level" => static ? "A" : "B", "formal_level" => "F0",
          "provenance" => provenance.merge("static_assertions" => static&.fetch("assertions", nil)).compact,
          "given" => call.slice("pre_state", "args", "kwargs", "block_given"),
          "expect" => call.slice("outcome", "post_state", "yields", "external_calls", "mutated_args")
        }
      end

      def short_name(name) = name.split("::").last
    end
  end
end
