# frozen_string_literal: true

module Bparity
  module Formal
    class ValueEnumerator
      def initialize(size:, depth:, alphabet: %w[a b], observed: [])
        @size = size
        @depth = depth
        @alphabet = alphabet
        @observed = observed
      end

      def values(type)
        generated = case type.to_s
                    when "Integer" then integers
                    when "String" then strings
                    when "Symbol" then (@observed.grep(Symbol) + @alphabet.map(&:to_sym)).uniq
                    when "NilClass", "nil" then [nil]
                    when "TrueClass", "FalseClass", "Boolean" then [false, true]
                    else raise ConfigurationError, "Cannot enumerate #{type}. Add an explicit input domain."
                    end
        klass = Object.const_get(type, false) if Object.const_defined?(type, false)
        (generated + (klass ? @observed.grep(klass) : [])).uniq
      end

      def arrays(element_type)
        return [[]] if @depth.zero?

        elements = values(element_type)
        (0..@size).flat_map { |length| elements.repeated_permutation(length).to_a }
      end

      private

      def integers = (-(@size - 1)..(@size - 1)).to_a

      def strings
        (0..@size).flat_map { |length| @alphabet.repeated_permutation(length).map(&:join) }
      end
    end

    class ExhaustiveRunner
      DEFAULT_MAX_CASES = 100_000
      DEFAULT_TIMEBOX = 300

      def initialize(old_callable:, new_callable:, domains:, size:, depth:, assumptions:, max_cases: DEFAULT_MAX_CASES,
                     timebox: DEFAULT_TIMEBOX, comparator: Verification::Comparator.new(mode: :strict),
                     old_error_mapper: nil, new_error_mapper: nil)
        @old_callable = old_callable
        @new_callable = new_callable
        @domains = domains
        @size = size
        @depth = depth
        @assumptions = assumptions
        @max_cases = max_cases
        @timebox = timebox
        @comparator = comparator
        @old_error_mapper = old_error_mapper
        @new_error_mapper = new_error_mapper
      end

      def run
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        count = 0
        counterexample = nil
        complete = true
        each_input do |input|
          if count >= @max_cases || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= @timebox
            complete = false
            break
          end
          count += 1
          expected = observe(@old_callable, input, @old_error_mapper)
          actual = observe(@new_callable, input, @new_error_mapper)
          differences = @comparator.compare(expected, actual)
          unless differences.empty?
            counterexample = { "input" => input, "differences" => differences }
            break
          end
        end
        result(count, complete, counterexample)
      end

      private

      def each_input(&)
        return yield([]) if @domains.empty?

        @domains.first.product(*@domains.drop(1), &)
      end

      def observe(callable, input, error_mapper)
        { "kind" => "return", "value" => Recording::Serializer.dump(callable.call(*input)) }
      rescue StandardError => e
        mapped = error_mapper ? error_mapper.call(e) : { class: e.class.name, message: e.message }
        normalized = mapped.to_h { |key, value| [key.to_s, value] }.compact
        { "kind" => "raise", **normalized }
      end

      def result(count, complete, counterexample)
        verdict = if counterexample then :difference_found
                  elsif complete then :no_difference_found
                  else :inconclusive
                  end
        details = complete ? {} : { "fallback" => "case limit or timebox reached; exhaustive claim withheld" }
        Result.new(level: :f2, verdict:,
                   scope: Scope.new(size: @size, depth: @depth, cases: count, exhaustive: complete,
                                    timebox: @timebox),
                   assumptions: @assumptions,
                   out_of_scope: ["values larger than size #{@size}", "structures deeper than #{@depth}"],
                   counterexample:, details:)
      end
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
          result = @callable.call(*args)
          violations = @checker.check(@invariants, result:, args:)
          return { "input" => shrink(args), "violations" => violations } unless violations.empty?
        rescue StandardError
          next
        end
        nil
      end

      private

      def shrink(args)
        args.map do |value|
          case value
          when String then value.empty? ? value : value[0]
          when Array then value.first(1)
          when Integer then value <=> 0
          else value
          end
        end
      end
    end
  end
end
