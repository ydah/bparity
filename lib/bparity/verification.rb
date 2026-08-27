# frozen_string_literal: true

module Bparity
  module Verification
    Result = Struct.new(:id, :status, :description, :differences, :provenance, keyword_init: true) do
      def to_h
        { "id" => id, "status" => status.to_s.upcase, "description" => description,
          "differences" => differences, "provenance" => provenance }
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
        (expected.keys | actual.keys).sort.flat_map do |key|
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
        length.times.flat_map { |index| call(expected[index], actual[index], "#{path}[#{index}]") }
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
        return [] if @mode == :contract

        compare_values(expected, actual)
      end

      private

      def compare_values(expected, actual, path = "$")
        if expected.is_a?(Float) && actual.is_a?(Float) && ((expected - actual).abs <= @float_tolerance * [
          expected.abs, actual.abs, 1
        ].max)
          return []
        end
        return Differ.call(expected, actual, path) unless expected.is_a?(Hash) && actual.is_a?(Hash)

        Differ.call(expected, actual, path)
      end
    end

    class TraceReplay
      def initialize(bundle:, adapter:, mode: nil)
        @bundle = bundle
        @adapter = adapter
        @comparator = Comparator.new(mode: mode || bundle.fetch("conformance_mode", "refinement"))
        @external_probe = ExternalProbe.new(adapter.externals).install!
      end

      def run
        @bundle.fetch("subjects").flat_map { |subject| replay_subject(subject) }
      end

      private

      def replay_subject(spec_subject)
        binding = @adapter.subjects[spec_subject["name"]]
        unless binding
          raise ConfigurationError, "Adapter subject #{spec_subject['name']} is missing. Add it to the adapter file."
        end

        spec_subject.fetch("operations").flat_map do |operation|
          operation.fetch("examples").map { |example| replay_example(binding, operation, example) }
        end
      end

      def replay_example(binding, operation_spec, example)
        waiver = @adapter.waivers[example["id"]]
        actual = invoke(binding, operation_spec["name"], example.fetch("given"))
        differences = @comparator.compare(example.fetch("expect"), actual)
        status = if differences.empty? then :pass
                 elsif waiver then :waived
                 else :fail
                 end
        Result.new(id: example["id"], status:, description: example.dig("provenance", "description"),
                   differences:, provenance: example["provenance"])
      end

      def invoke(binding, operation_name, given)
        subject = binding.build({})
        operation = binding.operations[operation_name] || Adapter::Operation.new(name: operation_name)
        args = Recording::Serializer.load(given.fetch("args", []))
        kwargs = Recording::Serializer.load(given.fetch("kwargs", {}))
        yields = []
        external_calls = @external_probe.capture do
          value = operation.invoke(subject, args, kwargs) { |*items| yields << Recording::Serializer.dump(items) }
          Recording::Serializer.dump(operation.map_return(value))
        end
        {
          "outcome" => { "kind" => "return", "value" => external_calls.fetch(:value) },
          "post_state" => Recording::Serializer.dump(binding.state_projection&.call(subject)),
          "yields" => yields, "external_calls" => external_calls.fetch(:calls), "mutated_args" => []
        }
      rescue StandardError => e
        mapped = stringify(operation&.map_error(e) || { class: e.class.name, message: e.message })
        { "outcome" => { "kind" => "raise", **mapped }, "post_state" => nil,
          "yields" => yields || [], "external_calls" => [], "mutated_args" => [] }
      end

      def stringify(hash) = hash.to_h { |key, value| [key.to_s, value] }
    end

    class ExternalProbe
      THREAD_KEY = :bparity_verification_external_calls

      def initialize(bindings)
        @bindings = bindings
      end

      def install!
        @bindings.each { |binding| install(binding) }
        self
      end

      def capture
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = []
        value = yield
        { value:, calls: Thread.current[THREAD_KEY] }
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      private

      def install(binding)
        target = Bparity.constantize(binding.target)
        mod = Module.new
        target.public_instance_methods(false).each do |method_name|
          mod.define_method(method_name) do |*args, **kwargs, &block|
            value = super(*args, **kwargs, &block)
            calls = Thread.current[THREAD_KEY]
            if calls
              raw = { "target" => binding.source, "method" => method_name.to_s,
                      "args" => Recording::Serializer.dump(args), "kwargs" => Recording::Serializer.dump(kwargs),
                      "outcome" => { "kind" => "return", "value" => Recording::Serializer.dump(value) } }
              mapper = binding.call_mappers[method_name.to_s]
              calls << (mapper ? mapper.call(raw) : raw)
            end
            value
          rescue StandardError => e
            Thread.current[THREAD_KEY]&.push({ "target" => binding.source, "method" => method_name.to_s,
                                               "args" => Recording::Serializer.dump(args),
                                               "kwargs" => Recording::Serializer.dump(kwargs),
                                               "outcome" => { "kind" => "raise", "class" => e.class.name,
                                                              "message" => e.message } })
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
