# frozen_string_literal: true

require "json"
require "open3"

module Bparity
  module Formal
    class Domain < Array
      attr_reader :truncated

      def initialize(values, truncated: false)
        super(values)
        @truncated = truncated
      end
    end

    class ValueEnumerator
      def initialize(size:, depth:, alphabet: %w[a b], observed: [], limit: nil)
        @size = size
        @depth = depth
        @alphabet = alphabet
        @observed = observed
        @limit = limit
      end

      def values(type)
        generated = case type.to_s
                    when "Integer" then integers
                    when "String" then strings
                    when "Symbol" then (@observed.grep(Symbol) + @alphabet.map(&:to_sym)).uniq
                    when "Array" then arrays(inferred_array_type)
                    when "Hash" then hashes(*inferred_hash_types)
                    when "NilClass", "nil" then [nil]
                    when "TrueClass", "FalseClass", "Boolean" then [false, true]
                    else return user_structures(type)
                    end
        klass = constant_class(type)
        bounded(Enumerator.new do |items|
          generated.each { |value| items << value }
          @observed.grep(klass).each { |value| items << value } if klass
        end)
      end

      def arrays(element_type)
        return [[]] if @depth.zero?

        elements = values(element_type)
        Enumerator.new do |items|
          (0..@size).each { |length| elements.repeated_permutation(length) { |value| items << value } }
        end
      end

      def hashes(key_type, value_type)
        return [{}] if @depth.zero?

        pairs = []
        values(key_type).product(values(value_type)) do |pair|
          pairs << pair
          break if @limit && pairs.length >= @limit
        end
        Enumerator.new do |results|
          results << {}
          (1..@size).each do |length|
            pairs.combination(length) do |items|
              hash = items.to_h
              results << hash if hash.length == length
            end
          end
        end
      end

      private

      def integers = (-@size..@size).to_a

      def strings
        Enumerator.new do |items|
          (0..@size).each do |length|
            @alphabet.repeated_permutation(length) { |characters| items << characters.join }
          end
        end
      end

      def bounded(values)
        unique = []
        seen = {}
        values.each do |value|
          next if seen[value]

          seen[value] = true
          unique << value
          return Domain.new(unique.first(@limit), truncated: true) if @limit && unique.length > @limit
        end
        Domain.new(unique)
      end

      def inferred_array_type
        @observed.grep(Array).flatten.first&.class&.name || "String"
      end

      def inferred_hash_types
        pair = @observed.grep(Hash).flat_map(&:to_a).first
        pair ? pair.map { |item| item.class.name } : %w[String String]
      end

      def user_structures(type)
        klass = Bparity.constantize(type.to_s)
        examples = @observed.grep(klass)
        if examples.empty?
          raise ConfigurationError,
                "Cannot enumerate #{type}. Add observed values or an explicit input domain."
        end

        fields = examples.flat_map(&:instance_variables).uniq
        domains = fields.to_h do |field|
          [field, (examples.map { |example| example.instance_variable_get(field) } + [nil]).uniq]
        end
        KoratEnumerator.new(klass:, fields:, domains:, limit: @limit).values
      end

      def constant_class(type)
        Bparity.constantize(type.to_s)
      rescue ConfigurationError
        nil
      end
    end

    class InputGenerator
      def initialize(size:, depth:, observed: [], alphabet: %w[a b])
        @enumerator = ValueEnumerator.new(size:, depth:, observed:, alphabet:)
      end

      def values(type)
        (@enumerator.values(type) + boundaries(type)).uniq
      end

      private

      def boundaries(type)
        case type.to_s
        when "Integer" then [0, -1, 2**62, -(2**62)]
        when "String" then ["", " ", "\xFF".b.force_encoding(Encoding::UTF_8)]
        else [nil]
        end
      end
    end

    class KoratEnumerator
      def initialize(klass:, fields:, domains:, predicate: ->(_value) { true }, limit: nil)
        @klass = klass
        @fields = fields.map(&:to_sym)
        @domains = domains.transform_keys(&:to_sym)
        @predicate = predicate
        @limit = limit
      end

      def values
        seen = {}
        results = []
        vectors.each do |vector|
          candidate = build(vector)
          next unless @predicate.call(candidate)

          signature = JSON.generate(shape(candidate))
          next if seen[signature]

          seen[signature] = true
          return Domain.new(results, truncated: true) if @limit && results.length >= @limit

          results << candidate
        end
        Domain.new(results)
      end

      private

      def vectors
        return [[]] if @fields.empty?

        Enumerator.new do |items|
          @domains.fetch(@fields.first).product(*@fields.drop(1).map { |field| @domains.fetch(field) }) do |vector|
            items << vector
          end
        end
      end

      def build(vector)
        @klass.allocate.tap do |candidate|
          @fields.zip(vector).each { |field, value| candidate.instance_variable_set(field, value) }
        end
      end

      def shape(value, seen = {}.compare_by_identity)
        return Recording::Serializer.dump(value) unless value.is_a?(@klass)
        return { "$ref" => seen.fetch(value) } if seen.key?(value)

        seen[value] = seen.length
        { "$class" => @klass.name,
          "$fields" => @fields.to_h { |field| [field, shape(value.instance_variable_get(field), seen)] } }
      end
    end

    class ExhaustiveRunner
      DEFAULT_MAX_CASES = 100_000
      DEFAULT_TIMEBOX = 300

      def initialize(new_callable:, domains:, size:, depth:, assumptions:, old_callable: nil,
                     contracts: [], preconditions: [], max_cases: DEFAULT_MAX_CASES,
                     timebox: DEFAULT_TIMEBOX, comparator: Verification::Comparator.new(mode: :strict),
                     new_error_mapper: nil)
        @old_callable = old_callable
        @new_callable = new_callable
        @domains = domains
        @size = size
        @depth = depth
        @assumptions = assumptions
        @max_cases = max_cases
        @timebox = timebox
        @comparator = comparator
        @new_error_mapper = new_error_mapper
        @contracts = contracts
        @preconditions = preconditions
        @checker = ContractChecker.new
        return unless @old_callable.nil? && @contracts.empty?

        raise ConfigurationError,
              "F2 needs a runnable legacy implementation or declared postconditions/invariants."
      end

      def run
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        count = 0
        visited = filtered = 0
        counterexample = nil
        fallback = @domains.any? { |domain| domain.respond_to?(:truncated) && domain.truncated } ||
                   total_cases > @max_cases
        inputs = fallback ? pairwise_inputs : exhaustive_inputs
        timed_out = false
        inputs.first(@max_cases).each do |input|
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= @timebox
            timed_out = true
            break
          end
          visited += 1
          unless admissible?(input)
            filtered += 1
            next
          end
          count += 1
          counterexample = compare(input)
          break if counterexample
        end
        complete = !fallback && !timed_out && visited == total_cases && count.positive?
        result(count, complete, counterexample, fallback ? count : 0, filtered)
      end

      private

      def exhaustive_inputs
        return [[]].each if @domains.empty?

        Enumerator.new do |items|
          @domains.first.product(*@domains.drop(1)) { |input| items << input }
        end
      end

      def total_cases = @domains.empty? ? 1 : @domains.reduce(1) { |count, domain| count * domain.length }

      def observe(callable, input, error_mapper)
        { "kind" => "return", "value" => Recording::Serializer.dump(callable.call(*input)) }
      rescue StandardError => e
        mapped = error_mapper ? error_mapper.call(e) : { class: e.class.name, message: Bparity.exception_message(e) }
        normalized = mapped.to_h { |key, value| [key.to_s, value] }.compact
        { "kind" => "raise", **normalized }
      end

      def compare(input)
        return compare_contract(input) unless @old_callable

        expected = observe(@old_callable, input, nil)
        actual = observe(@new_callable, input, @new_error_mapper)
        differences = @comparator.compare(expected, actual)
        return if differences.empty?

        { "input" => input, "expected" => expected, "actual" => actual,
          "differences" => differences }
      end

      def compare_contract(input)
        actual = observe(@new_callable, input, @new_error_mapper)
        result = actual["kind"] == "return" ? Recording::Serializer.load(actual["value"]) : nil
        violations = if actual["kind"] == "raise"
                       [{ "id" => "execution", "error" => "replacement raised #{actual['class']}" }]
                     else
                       @checker.check(@contracts, result:, args: input, kwargs: {})
                     end
        return if violations.empty?

        { "input" => input, "actual" => actual, "contracts" => @contracts, "violations" => violations,
          "differences" => violations.map do |violation|
            { "path" => "$.contracts.#{violation['id']}", "expected" => violation["expression"] || "no exception",
              "actual" => violation["error"] || false }
          end }
      end

      def admissible?(input)
        violations = @checker.check(@preconditions, result: nil, args: input, kwargs: {})
        error = violations.find { |violation| violation["error"] }
        if error
          raise ConfigurationError,
                "Cannot evaluate F2 precondition #{error['id']}: #{error['error']}. Fix the Spec Bundle."
        end
        violations.empty?
      end

      def pairwise_inputs
        return exhaustive_inputs if @domains.length < 2

        Enumerator.new do |items|
          seen = {}
          @domains.each_index.to_a.combination(2).each do |left, right|
            @domains[left].product(@domains[right]) do |left_value, right_value|
              input = @domains.map.with_index do |domain, index|
                { left => left_value, right => right_value }.fetch(index, domain.first)
              end
              next if seen[input]

              seen[input] = true
              items << input
            end
          end
        end
      end

      def result(count, complete, counterexample, fallback_count, filtered_count)
        verdict = if counterexample then :difference_found
                  elsif complete then :no_difference_found
                  else :inconclusive
                  end
        incomplete_note = if count.zero?
                            "no admissible input was checked; exhaustive claim withheld"
                          else
                            "case limit or timebox reached; exhaustive claim withheld"
                          end
        details = if complete
                    { "filtered_by_preconditions" => filtered_count }
                  else
                    { "fallback" => "pairwise", "fallback_cases" => fallback_count,
                      "filtered_by_preconditions" => filtered_count,
                      "note" => incomplete_note }
                  end
        legacy_scope = if @old_callable
                         "legacy behavior outside the selected operation"
                       else
                         "legacy behavior beyond declared contracts"
                       end
        Result.new(level: :f2, verdict:,
                   scope: Scope.new(size: @size, depth: @depth, cases: count,
                                    exhaustive: complete && counterexample.nil?,
                                    timebox: @timebox),
                   assumptions: @assumptions,
                   out_of_scope: [legacy_scope, "values outside the explicitly enumerated domains",
                                  "values larger than size #{@size}", "structures deeper than #{@depth}"],
                   counterexample:, details: details.merge("domains" => domain_summary))
      end

      def domain_summary
        @domains.map do |domain|
          { "count" => domain.length, "sample" => Recording::Serializer.dump(domain.first(5)),
            "truncated" => domain.respond_to?(:truncated) && domain.truncated }
        end
      end
    end

    module BoundedCounterexampleRSpec
      module_function

      def call(result:, subject_name:, operation_name:)
        return contract_spec(result, subject_name, operation_name) if result.counterexample["contracts"]

        input = result.counterexample.fetch("input")
        expected = result.counterexample.fetch("expected")
        <<~RUBY
          # frozen_string_literal: true

          require "bparity"
          require ENV["BPARITY_REPLACEMENT"] if ENV["BPARITY_REPLACEMENT"]
          load ENV.fetch("BPARITY_ADAPTER")

          RSpec.describe "F2 counterexample for #{subject_name}#{operation_name}" do
            it "matches the legacy observation for #{input.inspect}" do
              binding = Bparity.adapter_definition.subjects.fetch(#{subject_name.inspect})
              operation = binding.operations.fetch(#{operation_name.inspect})
              begin
                value = operation.invoke(binding.build({}), #{input.inspect}, {})
                value = operation.map_return(value)
                actual = { "kind" => "return", "value" => Bparity::Recording::Serializer.dump(value) }
              rescue StandardError => error
                mapped = operation.map_error(error).transform_keys(&:to_s)
                mapped["cause"] = error.cause&.class&.name unless mapped.key?("cause")
                actual = { "kind" => "raise", **mapped }
              end
              expect(actual).to eq(#{expected.inspect})
            end
          end
        RUBY
      end

      def contract_spec(result, subject_name, operation_name)
        input = result.counterexample.fetch("input")
        contracts = result.counterexample.fetch("contracts")
        <<~RUBY
          # frozen_string_literal: true

          require "bparity"
          require ENV["BPARITY_REPLACEMENT"] if ENV["BPARITY_REPLACEMENT"]
          load ENV.fetch("BPARITY_ADAPTER")

          RSpec.describe "F2 contract counterexample for #{subject_name}#{operation_name}" do
            it "satisfies the declared contracts for #{input.inspect}" do
              binding = Bparity.adapter_definition.subjects.fetch(#{subject_name.inspect})
              operation = binding.operations.fetch(#{operation_name.inspect})
              result = operation.map_return(operation.invoke(binding.build({}), #{input.inspect}, {}))
              violations = Bparity::Formal::ContractChecker.new.check(#{contracts.inspect},
                                                                       result: result, args: #{input.inspect}, kwargs: {})
              expect(violations).to be_empty
            end
          end
        RUBY
      end
      private_class_method :contract_spec
    end

    class PropertyRunner
      def initialize(callable:, invariants:, inputs:, checker: ContractChecker.new)
        @callable = callable
        @invariants = invariants
        @inputs = inputs
        @checker = checker
      end

      def run
        @inputs.each do |args|
          violations = violations_for(args)
          unless violations.empty?
            input = minimize(args)
            return { "input" => input, "violations" => violations_for(input) }
          end
        end
        nil
      end

      private

      def minimize(args)
        minimized = args.dup
        args.each_index do |index|
          shrink_candidates(args[index]).each do |candidate|
            trial = minimized.dup
            trial[index] = candidate
            minimized = trial unless violations_for(trial).empty?
          rescue StandardError
            next
          end
        end
        minimized
      end

      def violations_for(args)
        @checker.check(@invariants, result: @callable.call(*args), args:)
      rescue StandardError => e
        [{ "id" => "execution", "error" => Bparity.exception_message(e), "input" => { args: } }]
      end

      def shrink_candidates(value)
        candidates = case value
                     when String then ["", value[0]]
                     when Array then [[], value.first(1)]
                     when Integer then [0, value <=> 0]
                     else []
                     end
        candidates.uniq - [value]
      end
    end

    class DifferentialRunner
      def initialize(old_command:, new_command:, inputs:)
        @old_command = old_command
        @new_command = new_command
        @inputs = inputs
      end

      def run
        @inputs.filter_map do |input|
          expected = observe(@old_command, input)
          actual = observe(@new_command, input)
          differences = Verification::Differ.call(expected, actual)
          unless differences.empty?
            { "input" => input, "expected" => expected, "actual" => actual,
              "differences" => differences }
          end
        end
      end

      private

      def observe(command, input)
        output, error, status = Open3.capture3(*command, stdin_data: JSON.generate(input))
        unless status.success?
          raise ConfigurationError,
                "Differential process failed: #{error.strip}. Fix the command and run the comparison again."
        end

        JSON.parse(output)
      rescue JSON::ParserError
        raise ConfigurationError,
              "Differential process returned invalid JSON. Make it print one JSON observation and try again."
      end
    end
  end
end
