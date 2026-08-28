# frozen_string_literal: true

require "prism"
require "digest"
require "json"

module Bparity
  module Synthesis
    class InvariantMiner
      def mine(records)
        successful = records.filter_map do |record|
          outcome = record["outcome"]
          outcome["value"] if outcome&.fetch("kind", nil) == "return"
        end
        return [] if successful.length < 2

        candidates(successful).map.with_index(1) do |expression, index|
          { "id" => format("inv-%04d", index), "expr" => expression, "support" => successful.length,
            "confidence" => 1.0, "provenance_level" => "B", "formal_level" => "F0" }
        end
      end

      private

      def candidates(values)
        items = []
        items << "return != nil" if values.none?(&:nil?)
        classes = values.map(&:class).uniq
        items << "return.is_a?(#{classes.first})" if classes.one? && %w[String Integer Array
                                                                        Hash].include?(classes.first.name)
        if values.all? { |value| value.is_a?(String) && value.match?(/\A[a-z0-9-]*\z/) }
          items << "return.match?(/\\A[a-z0-9-]*\\z/)"
        end
        items
      end
    end

    class MetamorphicDetector
      def detect(callable, samples)
        return [] if samples.empty?

        relations = []
        relations << "idempotent" if holds? do
          samples.all? do |sample|
            callable.call(callable.call(sample)) == callable.call(sample)
          end
        end
        relations << "permutation_invariant" if samples.all?(Array) && holds? do
          samples.all? { |sample| callable.call(sample.reverse) == callable.call(sample) }
        end
        if samples.all?(Numeric)
          relations << "additive" if holds? do
            samples.product(samples).all? do |left, right|
              callable.call(left + right) == callable.call(left) + callable.call(right)
            end
          end
          relations << "monotonic" if holds? do
            samples.sort.each_cons(2).all? do |left, right|
              callable.call(left) <= callable.call(right)
            end
          end
        end
        relations
      end

      private

      def holds?
        yield
      rescue StandardError
        false
      end
    end

    class StaticExtractor
      SPEC_CALLS = %i[describe context it specify].freeze
      ASSERTIONS = %i[eq eql equal raise_error assert assert_equal assert_raises].freeze
      UNSUPPORTED = Object.new.freeze

      def extract_tests(paths)
        Array(paths).flat_map { |path| extract_test_file(path) }
      end

      def extract_source(paths)
        Array(paths).flat_map do |path|
          result = Prism.parse_file(path)
          raise Error, "Cannot parse #{path}. Fix its Ruby syntax and try again." unless result.success?

          source_facts(result.value, path)
        end
      end

      private

      def extract_test_file(path)
        result = Prism.parse_file(path)
        raise Error, "Cannot parse #{path}. Fix its Ruby syntax and try again." unless result.success?

        extract_spec_nodes(result.value, path, []) + extract_minitest_nodes(result.value, path)
      end

      def extract_minitest_nodes(node, path, owner = nil)
        owner = node.constant_path.location.slice if node.type == :class_node
        item = minitest_item(node, path, owner) if node.type == :def_node && node.name.to_s.start_with?("test_")
        [item, *node.compact_child_nodes.flat_map { |child| extract_minitest_nodes(child, path, owner) }].compact
      end

      def minitest_item(node, path, owner)
        assertions = nodes(node.body).filter_map do |child|
          child.name.to_s if child.type == :call_node && ASSERTIONS.include?(child.name)
        end.uniq
        description = node.name.to_s.delete_prefix("test_").tr("_", " ")
        { "subject" => owner, "description" => [owner, description].compact.join(" "),
          "location" => "#{path}:#{node.location.start_line}", "assertions" => assertions }
          .merge(extract_minitest_expectation(node.body) || {})
      end

      def extract_minitest_expectation(body)
        nodes(body).filter_map { |node| minitest_expectation(node) }.first
      end

      def minitest_expectation(node)
        return unless minitest_assertion?(node)

        expected, invocation = minitest_parts(node)
        return unless expected && invocation&.type == :call_node

        arguments = invocation.arguments&.arguments || []
        values = arguments.map { |argument| static_literal(argument) }
        return if values.any? { |value| value.equal?(UNSUPPORTED) }

        { "subject" => invocation_subject(invocation), "operation" => "##{invocation.name}",
          "arguments" => values, "expected_outcome" => expected }
      end

      def minitest_assertion?(node)
        node.type == :call_node && %i[assert_equal assert_raises].include?(node.name)
      end

      def minitest_parts(node)
        arguments = node.arguments&.arguments || []
        return [static_outcome_for(arguments.first), arguments.at(1)] if node.name == :assert_equal

        [{ "kind" => "raise", "class" => arguments.first&.location&.slice }, block_call(node)]
      end

      def static_outcome_for(node)
        value = node && static_literal(node)
        return if value.equal?(UNSUPPORTED)

        { "kind" => "return", "value" => Recording::Serializer.dump(value) }
      end

      def block_call(node)
        body = node.block&.body
        body&.type == :statements_node ? body.body.last : body
      end

      def invocation_subject(invocation)
        receiver = invocation.receiver
        receiver = receiver.receiver if receiver&.type == :call_node && receiver.name == :new
        receiver&.location&.slice
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
        { "subject" => context.first, "description" => context.join(" "),
          "location" => "#{path}:#{node.location.start_line}", "assertions" => assertions }
          .merge(extract_expectation(node.block.body) || {})
      end

      def extract_expectation(body)
        nodes(body).filter_map { |node| expectation(node) }.first
      end

      def expectation(node)
        return unless rspec_expectation?(node)

        expect_call = node.receiver
        matcher = node.arguments&.arguments&.first
        return unless matcher&.type == :call_node

        invocation = expected_invocation(expect_call)
        return unless invocation&.type == :call_node

        arguments = invocation.arguments&.arguments || []
        values = arguments.map { |argument| static_literal(argument) }
        return if values.any? { |value| value.equal?(UNSUPPORTED) }

        outcome = static_outcome(matcher)
        return unless outcome

        { "operation" => "##{invocation.name}", "arguments" => values, "expected_outcome" => outcome }
      end

      def rspec_expectation?(node)
        node.type == :call_node && node.name == :to && node.receiver&.type == :call_node &&
          node.receiver.name == :expect
      end

      def expected_invocation(expect_call)
        direct = expect_call.arguments&.arguments&.first
        return direct if direct

        body = expect_call.block&.body
        body&.type == :statements_node ? body.body.last : body
      end

      def static_literal(node)
        case node.type
        when :string_node then node.unescaped
        when :integer_node, :float_node then node.value
        when :nil_node then nil
        when :true_node then true
        when :false_node then false
        when :symbol_node then node.unescaped.to_sym
        else UNSUPPORTED
        end
      end

      def static_outcome(matcher)
        argument = matcher.arguments&.arguments&.first
        case matcher.name
        when :eq, :eql, :equal
          value = argument && static_literal(argument)
          return if value.equal?(UNSUPPORTED)

          { "kind" => "return", "value" => Recording::Serializer.dump(value) }
        when :raise_error
          return unless argument

          { "kind" => "raise", "class" => argument.location.slice }
        end
      end

      def nodes(root, &block)
        return enum_for(__method__, root) unless block_given?

        yield root
        root.compact_child_nodes.each { |child| nodes(child, &block) }
      end

      def source_facts(node, path, owner = nil, method_name = nil, parameters = [])
        return [] unless node

        owner = source_owner(node, owner)
        if node.type == :def_node
          method_name = node.name
          parameters = node.parameters ? node.parameters.requireds.map(&:name) : []
        end
        fact = guard_fact(node, path, owner, method_name, parameters)
        [fact, *node.compact_child_nodes.flat_map do |child|
          source_facts(child, path, owner, method_name, parameters)
        end].compact
      end

      def source_owner(node, owner)
        return owner unless %i[class_node module_node].include?(node.type)

        name = node.constant_path.location.slice
        name.include?("::") ? name : [owner, name].compact.join("::")
      end

      def guard_fact(node, path, owner, method_name, parameters)
        return unless node.type == :if_node && method_name && contains_raise?(node.statements)

        predicate = node.predicate.location.slice
        parameters.each_with_index do |name, index|
          predicate = predicate.gsub(/\b#{Regexp.escape(name.to_s)}\b/, "args[#{index}]")
        end
        keyword = node.if_keyword_loc&.slice
        expression = keyword == "unless" ? predicate : "!(#{predicate})"
        { "kind" => "precondition", "owner" => owner, "operation" => "##{method_name}",
          "expr" => expression, "location" => "#{path}:#{node.location.start_line}",
          "source" => node.location.slice }
      end

      def contains_raise?(node)
        node && nodes(node).any? { |child| child.type == :call_node && child.name == :raise }
      end

      def literal(node)
        return unless node
        return node.unescaped if node.respond_to?(:unescaped)
        return node.value.to_s if node.respond_to?(:value)

        node.location.slice
      end
    end

    class Synthesizer
      MAX_EXAMPLES_PER_OPERATION = 50
      ASSUMPTIONS = [
        { "id" => "H1", "name" => "world_freeze", "enforced_by" => "runtime monitor" },
        { "id" => "H2", "name" => "dynamic_methods_declared", "enforced_by" => "discovery" },
        { "id" => "H3", "name" => "no_eval", "enforced_by" => "Prism static detection" },
        { "id" => "H4", "name" => "runtime_identity_unobserved", "enforced_by" => "serializer" },
        { "id" => "H5", "name" => "ieee_754", "enforced_by" => "declaration only" },
        { "id" => "H6", "name" => "exceptions_are_outputs", "enforced_by" => "recorder" },
        { "id" => "H7", "name" => "single_thread", "enforced_by" => "declaration only" }
      ].freeze

      def initialize(records:, static_examples: [], source_facts: [])
        @records = records
        @static_examples = static_examples
        @source_facts = source_facts
        @invariant_miner = InvariantMiner.new
      end

      def call
        subject_items = subjects
        {
          "spec_bundle_version" => SpecBundle::VERSION,
          "generated_at" => Time.now.utc.iso8601,
          "conformance_mode" => "refinement",
          "canonicalization" => canonicalization,
          "verification_assumptions" => ASSUMPTIONS,
          "subjects" => subject_items,
          "lts" => learned_models,
          "static_facts" => @source_facts.reject { |fact| fact["kind"] == "uncovered_branch" },
          "gaps" => synthesis_gaps,
          "waivers" => []
        }
      end

      private

      def canonicalization
        configurations = @records.filter_map { |record| record["canonicalization"] }.uniq
        if configurations.length > 1
          raise Error, "The corpus contains conflicting canonicalization settings. Record the corpus again."
        end

        configurations.first || {}
      end

      def subjects
        recorded = @records.group_by { |record| record["subject"] }.map do |name, records|
          item = { "name" => short_name(name), "old_class" => name, "operations" => operations(name, records) }
          item["lts_ref"] = lts_id(name) if stateful?(records)
          item
        end
        recorded + static_subjects(recorded.map { |subject| subject["old_class"] })
      end

      def static_subjects(recorded_names)
        executable = @static_examples.select { |example| example["operation"] && example["subject"] }
        executable.group_by { |example| example["subject"] }.filter_map do |name, examples|
          next if recorded_names.any? { |recorded| short_name(recorded) == short_name(name) }

          { "name" => short_name(name), "old_class" => name, "operations" => static_operations(examples) }
        end
      end

      def static_operations(examples)
        examples.group_by { |example| example.fetch("operation") }.map do |name, operation_examples|
          { "name" => name,
            "params" => static_params(operation_examples),
            "preconditions" => [], "invariants" => [],
            "examples" => operation_examples.map { |example| static_example(example) } }
        end
      end

      def static_params(examples)
        count = examples.map { |example| example.fetch("arguments").length }.max || 0
        count.times.map do |index|
          values = examples.select { |example| example.fetch("arguments").length > index }
                           .map { |example| example.fetch("arguments")[index] }
          { "name" => "arg#{index}", "types" => values.map { |value| value.class.name }.uniq,
            "observed_values" => values.map { |value| Recording::Serializer.dump(value) }.uniq }
        end
      end

      def static_example(example)
        digest = Digest::SHA256.hexdigest(example.values_at("location", "description", "operation").join("\0"))[0, 12]
        { "id" => "static-#{digest}", "provenance_level" => "C", "formal_level" => "F0",
          "provenance" => example.slice("description", "location").merge("derived_from" => ["static_assertion"]),
          "given" => { "args" => Recording::Serializer.dump(example.fetch("arguments")),
                       "kwargs" => Recording::Serializer.dump({}), "block_given" => false },
          "expect" => { "outcome" => example.fetch("expected_outcome") } }
      end

      def synthesis_gaps
        gaps = @source_facts.select { |fact| fact["kind"] == "uncovered_branch" }
        return gaps unless @records.empty?

        gaps + [{ "kind" => "no_runtime_recording",
                  "note" => "Only static assertions were extracted; unasserted legacy behavior is unknown." }]
      end

      def learned_models
        @records.group_by { |record| record["subject"] }.filter_map do |name, records|
          next unless stateful?(records)

          Formal::PassiveLearner.new.learn(records).to_h.merge("id" => lts_id(name),
                                                               "learned_by" => "passive corpus projection")
        end
      end

      def stateful?(records) = records.any? { |record| record["pre_state"] || record["post_state"] }
      def lts_id(name) = "lts-#{short_name(name).downcase}"

      def operations(subject_name, records)
        records.group_by { |record| record["operation"] }.map do |name, calls|
          sampled = representative_sample(calls)
          { "name" => name, "params" => params(calls), "examples" => sampled.map { |call| example(call) },
            "preconditions" => preconditions(subject_name, name), "invariants" => @invariant_miner.mine(calls) }
        end
      end

      def representative_sample(calls)
        signatures = {}
        diverse = calls.select do |call|
          signature = JSON.generate(call.values_at("args", "kwargs", "outcome", "post_state", "external_calls"))
          !signatures.key?(signature) && (signatures[signature] = true)
        end
        (diverse + calls).uniq { |call| call["id"] }.first(MAX_EXAMPLES_PER_OPERATION)
      end

      def preconditions(subject_name, operation_name)
        @source_facts.each_with_index.filter_map do |fact, index|
          next unless fact["kind"] == "precondition" && fact["owner"] == subject_name &&
                      fact["operation"] == operation_name

          fact.slice("expr", "location", "source").merge("id" => format("pre-%04d", index + 1),
                                                         "provenance_level" => "C", "formal_level" => "F1")
        end
      end

      def params(calls)
        count = calls.map { |call| call.fetch("args", []).length }.max || 0
        count.times.map do |index|
          serialized = calls.filter { |call| call.fetch("args", []).length > index }
                            .map { |call| call.fetch("args")[index] }
          observed = serialized.map { |value| Recording::Serializer.load(value) }
          { "name" => "arg#{index}", "types" => observed.map { |value| value.class.name }.uniq,
            "observed_values" => serialized.uniq }
        end
      end

      def example(call)
        provenance = call["provenance"] || {}
        static = @static_examples.find { |item| matching_static_evidence?(item, call, provenance) }
        {
          "id" => call["id"], "provenance_level" => static ? "A" : "B", "formal_level" => "F0",
          "provenance" => provenance.merge("static_assertions" => static&.fetch("assertions", nil)).compact,
          "given" => call.slice("pre_state", "args", "kwargs", "block_given"),
          "expect" => call.slice("outcome", "post_state", "yields", "external_calls", "mutated_args")
        }
      end

      def matching_static_evidence?(item, call, provenance)
        item["description"] == provenance["description"] && item["operation"] == call["operation"] &&
          matching_subject?(item["subject"].to_s, call["subject"]) &&
          Recording::Serializer.dump(item.fetch("arguments", [])) == call.fetch("args", []) &&
          matching_outcome?(item, call)
      end

      def matching_subject?(static_name, recorded_name)
        static_name == recorded_name || (!static_name.include?("::") && static_name == short_name(recorded_name))
      end

      def matching_outcome?(item, call)
        expected = item["expected_outcome"]
        actual = call["outcome"]
        expected.is_a?(Hash) && actual.is_a?(Hash) && expected == actual.slice(*expected.keys)
      end

      def short_name(name) = name.split("::").last
    end
  end
end
