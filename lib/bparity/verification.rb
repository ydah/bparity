# frozen_string_literal: true

module Bparity
  module Verification
    Result = Struct.new(:id, :status, :description, :differences, :provenance, :waiver, keyword_init: true) do
      def to_h
        { "id" => id, "status" => status.to_s.upcase, "description" => description,
          "differences" => differences, "provenance" => provenance,
          "waiver" => waiver&.to_h&.transform_keys(&:to_s) }
      end
    end

    module Differ
      MISSING = Object.new.freeze

      module_function

      def call(expected, actual, path = "$")
        return [] if expected == actual
        return hash_diff(expected, actual, path) if expected.is_a?(Hash) && actual.is_a?(Hash)
        return array_diff(expected, actual, path) if expected.is_a?(Array) && actual.is_a?(Array)

        [{ "path" => path, "expected" => expected, "actual" => actual }]
      end

      def hash_diff(expected, actual, path)
        (expected.keys | actual.keys).sort_by(&:to_s).flat_map do |key|
          if !expected.key?(key) || !actual.key?(key)
            expected_value = expected.fetch(key, MISSING)
            actual_value = actual.fetch(key, MISSING)
            [{ "path" => "#{path}.#{key}", "expected" => display(expected_value),
               "actual" => display(actual_value) }]
          else
            call(expected[key], actual[key], "#{path}.#{key}")
          end
        end
      end
      private_class_method :hash_diff

      def display(value) = value.equal?(MISSING) ? "<missing>" : value
      private_class_method :display

      def array_diff(expected, actual, path)
        length = [expected.length, actual.length].max
        length.times.flat_map do |index|
          expected_value = expected.fetch(index, MISSING)
          actual_value = actual.fetch(index, MISSING)
          if expected_value.equal?(MISSING) || actual_value.equal?(MISSING)
            [{ "path" => "#{path}[#{index}]", "expected" => display(expected_value),
               "actual" => display(actual_value) }]
          else
            call(expected_value, actual_value, "#{path}[#{index}]")
          end
        end
      end
      private_class_method :array_diff
    end

    class Comparator
      MODES = %i[strict refinement contract].freeze

      def initialize(mode: :refinement, float_tolerance: Float::EPSILON)
        @mode = mode.to_sym
        @float_tolerance = float_tolerance
        return if MODES.include?(@mode)

        raise ConfigurationError,
              "Unknown conformance mode: #{mode}. Use strict, refinement, or contract."
      end

      def compare(expected, actual)
        if @mode == :contract
          raise ConfigurationError,
                "Contract comparison requires operation contracts. Run it through Verification::Runner."
        end

        compare_values(expected, actual)
      end

      def contract? = @mode == :contract

      private

      def compare_values(expected, actual, path = "$")
        if expected.is_a?(Float) && actual.is_a?(Float) && ((expected - actual).abs <= @float_tolerance * [
          expected.abs, actual.abs, 1
        ].max)
          return []
        end
        return refinement_diff(expected, actual, path) if @mode == :refinement && expected.is_a?(Hash)
        return Differ.call(expected, actual, path) unless expected.is_a?(Hash) && actual.is_a?(Hash)

        Differ.call(expected, actual, path)
      end

      def refinement_diff(expected, actual, path)
        return Differ.call(expected, actual, path) unless actual.is_a?(Hash)

        expected.flat_map do |key, value|
          next [{ "path" => "#{path}.#{key}", "expected" => value, "actual" => "<missing>" }] unless actual.key?(key)

          compare_values(value, actual[key], "#{path}.#{key}")
        end
      end
    end

    class TraceReplay
      def initialize(bundle:, adapter:, mode: nil)
        @bundle = bundle
        @adapter = adapter
        @canonicalization = bundle.fetch("canonicalization", {}).transform_keys(&:to_sym)
        @canonicalizer = Recording::Canonicalizer.new(@canonicalization)
        @comparator = Comparator.new(mode: mode || bundle.fetch("conformance_mode", "refinement"),
                                     float_tolerance: @canonicalization.fetch(:float_tolerance, Float::EPSILON))
        @refinement_comparator = Comparator.new(mode: :refinement)
        @contract_checker = Formal::ContractChecker.new
        @external_probe = ExternalProbe.new(adapter.externals).install!
      end

      def run
        Recording::Determinism.apply(@canonicalization)
        results = @bundle.fetch("subjects").flat_map { |subject| replay_subject(subject) }
        unused = @adapter.waivers.keys - results.map(&:id)
        unless unused.empty?
          raise ConfigurationError,
                "Waiver IDs were not found in the Spec Bundle: #{unused.join(', ')}. Remove or correct them."
        end
        results
      ensure
        Recording::Determinism.clear
      end

      private

      def replay_subject(spec_subject)
        binding = @adapter.subjects[spec_subject["name"]]
        unless binding
          raise ConfigurationError, "Adapter subject #{spec_subject['name']} is missing. Add it to the adapter file."
        end

        subjects = {}
        calls = spec_subject.fetch("operations").flat_map do |operation|
          operation.fetch("examples").map { |example| [operation, example] }
        end
        calls.sort_by { |_operation, example| example.fetch("id") }.map do |operation, example|
          provenance = example.dig("provenance", "example_id") || example.fetch("id")
          subject = subjects[provenance] ||= binding.build({})
          replay_example(binding, subject, operation, example)
        end
      end

      def replay_example(binding, subject, operation_spec, example)
        waiver = @adapter.waivers[example["id"]]
        actual = @canonicalizer.call(invoke(binding, subject, operation_spec["name"], example.fetch("given")))
        differences = if @comparator.contract?
                        contract_differences(operation_spec, example, actual)
                      else
                        @comparator.compare(example.fetch("expect"), actual)
                      end
        status = if differences.empty? then :pass
                 elsif waiver then :waived
                 else :fail
                 end
        Result.new(id: example["id"], status:, description: example.dig("provenance", "description"),
                   differences:, provenance: example["provenance"], waiver: status == :waived ? waiver : nil)
      end

      def invoke(binding, subject, operation_name, given)
        operation = binding.operations[operation_name] || Adapter::Operation.new(name: operation_name)
        args = Recording::Serializer.load(given.fetch("args", []))
        kwargs = Recording::Serializer.load(given.fetch("kwargs", {}))
        before_args = Recording::Serializer.dump(args)
        yields = []
        external_calls = @external_probe.capture do
          value = operation.invoke(subject, args, kwargs) { |*items| yields << Recording::Serializer.dump(items) }
          Recording::Serializer.dump(operation.map_return(value))
        end
        {
          "outcome" => { "kind" => "return", "value" => external_calls.fetch(:value) },
          "post_state" => Recording::Serializer.dump(binding.state_projection&.call(subject)),
          "yields" => yields, "external_calls" => external_calls.fetch(:calls),
          "mutated_args" => mutated_indices(before_args, Recording::Serializer.dump(args))
        }
      rescue StandardError => e
        mapped = stringify(operation&.map_error(e) || { class: e.class.name, message: Bparity.exception_message(e) })
        mapped["cause"] = e.cause&.class&.name unless mapped.key?("cause")
        post_state = Recording::Serializer.dump(binding.state_projection&.call(subject))
        { "outcome" => { "kind" => "raise", **mapped }, "post_state" => post_state,
          "yields" => yields || [], "external_calls" => e.instance_variable_get(:@bparity_external_calls) || [],
          "mutated_args" => mutated_indices(before_args || [], Recording::Serializer.dump(args || [])) }
      end

      def stringify(hash) = hash.to_h { |key, value| [key.to_s, value] }

      def mutated_indices(before, after)
        [before.length, after.length].max.times.reject { |index| before[index] == after[index] }
      end

      def contract_differences(operation_spec, example, actual)
        preconditions = operation_spec.fetch("preconditions", [])
        constraints = operation_spec.fetch("postconditions", []) + operation_spec.fetch("invariants", [])
        return @refinement_comparator.compare(example.fetch("expect"), actual) if constraints.empty?

        context = contract_context(example, actual)
        precondition_violations = @contract_checker.check(preconditions, context)
        errors = precondition_violations.select { |violation| violation["error"] }
        unless errors.empty?
          return errors.map do |violation|
            { "path" => "$.contracts.#{violation['id']}", "expected" => violation["expression"],
              "actual" => violation["error"] }
          end
        end
        return @refinement_comparator.compare(example.fetch("expect"), actual) unless precondition_violations.empty?

        @contract_checker.check(constraints, context).map do |violation|
          { "path" => "$.contracts.#{violation['id']}", "expected" => violation["expression"],
            "actual" => violation["error"] || false }
        end
      end

      def contract_context(example, actual)
        outcome = actual.fetch("outcome")
        { result: outcome["kind"] == "return" ? Recording::Serializer.load(outcome["value"]) : nil,
          args: Recording::Serializer.load(example.dig("given", "args") || []),
          kwargs: Recording::Serializer.load(example.dig("given", "kwargs") || {}),
          pre_state: Recording::Serializer.load(example.dig("given", "pre_state")),
          post_state: Recording::Serializer.load(actual["post_state"]) }
      end
    end

    class ExternalProbe
      THREAD_KEY = :bparity_verification_external_calls

      def initialize(bindings)
        @bindings = bindings
        @bindings_by_target = bindings.to_h { |binding| [Bparity.constantize(binding.target), binding] }
      end

      def install!
        @bindings.each { |binding| install(binding) }
        self
      end

      def capture
        previous = Thread.current[THREAD_KEY]
        context = Thread.current[THREAD_KEY] = { calls: [], bindings: @bindings_by_target }
        value = yield
        { value:, calls: context.fetch(:calls) }
      rescue StandardError => e
        e.instance_variable_set(:@bparity_external_calls, context.fetch(:calls))
        raise
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      private

      def install(binding)
        target = Bparity.constantize(binding.target)
        installed = target.instance_variable_get(:@bparity_external_probe_methods) || []
        methods = target.public_instance_methods(false) - installed
        return if methods.empty?

        target.instance_variable_set(:@bparity_external_probe_methods, installed | methods)
        mod = Module.new
        methods.each do |method_name|
          mod.define_method(method_name) do |*args, **kwargs, &block|
            value = super(*args, **kwargs, &block)
            context = Thread.current[THREAD_KEY]
            current_binding = context&.dig(:bindings, target)
            if current_binding
              raw = { "target" => current_binding.source, "method" => method_name.to_s,
                      "args" => Recording::Serializer.dump(args), "kwargs" => Recording::Serializer.dump(kwargs),
                      "outcome" => { "kind" => "return", "value" => Recording::Serializer.dump(value) } }
              mapper = current_binding.call_mappers[method_name.to_s]
              context.fetch(:calls) << (mapper ? mapper.call(raw) : raw)
            end
            value
          rescue StandardError => e
            context = Thread.current[THREAD_KEY]
            current_binding = context&.dig(:bindings, target)
            if current_binding
              context.fetch(:calls) << { "target" => current_binding.source, "method" => method_name.to_s,
                                         "args" => Recording::Serializer.dump(args),
                                         "kwargs" => Recording::Serializer.dump(kwargs),
                                         "outcome" => { "kind" => "raise", "class" => e.class.name,
                                                        "message" => Bparity.exception_message(e) } }
            end
            raise
          end
        end
        target.prepend(mod)
      end
    end

    class Runner
      attr_reader :results

      def initialize(bundle:, adapter:, mode: nil)
        @replay = TraceReplay.new(bundle:, adapter:, mode:)
      end

      def run
        @results = @replay.run
      end

      def success? = results&.none? { |result| result.status == :fail }
    end
  end
end
