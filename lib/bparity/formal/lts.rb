# frozen_string_literal: true

require "json"

module Bparity
  module Formal
    module LtsEncoding
      module_function

      def output(outcome)
        JSON.generate(normalize(outcome))
      end

      def normalize(value)
        case value
        when Hash
          value.compact.sort_by { |key, _item| key.to_s }
               .to_h { |key, item| [key.to_s, normalize(item)] }
        when Array then value.map { |item| normalize(item) }
        else value
        end
      end
    end

    Transition = Struct.new(:from, :input, :output, :to, keyword_init: true) do
      def to_h = { "from" => from, "input" => input, "output" => output, "to" => to }
    end

    class LTS
      attr_reader :initial, :transitions

      def initialize(initial:, transitions: [])
        @initial = initial
        @transitions = transitions.map do |transition|
          transition.is_a?(Transition) ? transition : Transition.new(**transition.transform_keys(&:to_sym))
        end
      end

      def states = ([initial] + transitions.flat_map { |transition| [transition.from, transition.to] }).uniq.sort
      def alphabet = transitions.map(&:input).uniq.sort
      def outgoing(state) = transitions.select { |transition| transition.from == state }
      def step(state, input) = outgoing(state).find { |transition| transition.input == input }

      def to_h
        { "initial" => initial, "states" => states, "alphabet" => alphabet,
          "transitions" => transitions.map(&:to_h) }
      end

      def self.from_h(value)
        new(initial: value.fetch("initial"), transitions: value.fetch("transitions", []))
      end
    end

    class PassiveLearner
      def learn(records)
        usable = records.select { |record| record.key?("pre_state") && record.key?("post_state") }
        if usable.empty?
          raise ConfigurationError,
                "The corpus has no state projections. Add a state block to the boundary."
        end

        labels = usable.flat_map { |record| [state_label(record["pre_state"]), state_label(record["post_state"])] }.uniq
        names = labels.sort.each_with_index.to_h { |label, index| [label, "s#{index}"] }
        transitions = usable.map do |record|
          Transition.new(from: names.fetch(state_label(record["pre_state"])), input: record.fetch("operation"),
                         output: output_label(record.fetch("outcome")),
                         to: names.fetch(state_label(record["post_state"])))
        end.uniq(&:to_h)
        LTS.new(initial: names.fetch(state_label(usable.first["pre_state"])), transitions:)
      end

      private

      def state_label(state) = JSON.generate(state)
      def output_label(outcome) = LtsEncoding.output(outcome)
    end

    LearnedModel = Struct.new(:lts, :complete, :query_count, :algorithm, keyword_init: true)
    ObservedOutput = Struct.new(:value)

    class ActiveLearner
      def initialize(factory:, state_projection:, operations:, state_limit: 500)
        @factory = factory
        @state_projection = state_projection
        @operations = operations
        @state_limit = state_limit
      end

      def learn
        initial_subject = @factory.call
        initial_label = state_label(initial_subject)
        paths = { initial_label => [] }
        queue = [initial_label]
        transitions = []
        queries = 0
        until queue.empty?
          from = queue.shift
          @operations.each do |name, operation|
            subject = replay(paths.fetch(from))
            output = observe(subject, operation)
            queries += 1
            target = state_label(subject)
            transitions << Transition.new(from:, input: name, output:, to: target)
            next if paths.key?(target)
            return learned(initial_label, transitions, false, queries) if paths.length >= @state_limit

            paths[target] = paths.fetch(from) + [name]
            queue << target
          end
        end
        learned(initial_label, transitions, true, queries)
      end

      private

      def replay(path)
        subject = @factory.call
        path.each { |name| observe(subject, @operations.fetch(name)) }
        subject
      end

      def observe(subject, operation)
        value = operation.call(subject)
        return LtsEncoding.output(value.value) if value.is_a?(ObservedOutput)

        LtsEncoding.output("kind" => "return", "value" => Recording::Serializer.dump(value))
      rescue StandardError => e
        LtsEncoding.output("kind" => "raise", "class" => e.class.name, "message" => e.message)
      end

      def state_label(subject) = JSON.generate(Recording::Serializer.dump(@state_projection.call(subject)))

      def learned(initial, transitions, complete, queries)
        labels = ([initial] + transitions.flat_map { |transition| [transition.from, transition.to] }).uniq.sort
        names = labels.each_with_index.to_h { |label, index| [label, "s#{index}"] }
        normalized = transitions.map do |transition|
          Transition.new(from: names.fetch(transition.from), input: transition.input,
                         output: transition.output, to: names.fetch(transition.to))
        end
        LearnedModel.new(lts: LTS.new(initial: names.fetch(initial), transitions: normalized), complete:,
                         query_count: queries, algorithm: "active state exploration")
      end
    end

    class LtsEquivalence
      def compare(old_lts, new_lts, relation: :trace, assumptions: %i[h1 h6 h7], exact: true)
        unless %i[trace bisim].include?(relation.to_sym)
          raise ConfigurationError, "Unsupported LTS relation #{relation}. Use trace or bisim."
        end

        counterexample = distinguishing_sequence(old_lts, new_lts)
        verdict = if counterexample then :difference_found
                  elsif exact then :no_difference_found
                  else :inconclusive
                  end
        Result.new(level: :f3, verdict:,
                   scope: Scope.new(size: [old_lts.states.length, new_lts.states.length].max,
                                    depth: nil, cases: visited_count, exhaustive: exact),
                   assumptions:, out_of_scope: ["operations outside the learned alphabet", "unprojected state"],
                   counterexample: counterexample && { "sequence" => counterexample },
                   details: details(old_lts, new_lts, relation, exact))
      end

      private

      def distinguishing_sequence(old_lts, new_lts)
        @visited = {}
        queue = [[old_lts.initial, new_lts.initial, []]]
        until queue.empty?
          old_state, new_state, path = queue.shift
          next if @visited[[old_state, new_state]]

          @visited[[old_state, new_state]] = true
          inputs = (old_lts.outgoing(old_state).map(&:input) | new_lts.outgoing(new_state).map(&:input)).sort
          inputs.each do |input|
            old_transition = old_lts.step(old_state, input)
            new_transition = new_lts.step(new_state, input)
            return path + [input] unless old_transition && new_transition
            return path + [input] unless old_transition.output == new_transition.output

            queue << [old_transition.to, new_transition.to, path + [input]]
          end
        end
        nil
      end

      def visited_count = @visited.length

      def details(old_lts, new_lts, relation, exact)
        { "relation" => relation.to_s,
          "lts_o" => model_details(old_lts), "lts_n" => model_details(new_lts),
          "equivalence_query" => { "method" => "paired-state breadth-first search", "exact" => exact },
          "caveat" => "This result applies to the learned models, not to the complete implementations." }
      end

      def model_details(lts)
        { "states" => lts.states.length, "transitions" => lts.transitions.length, "alphabet" => lts.alphabet }
      end
    end

    module AldebaranExporter
      module_function

      def call(lts)
        states = lts.states.each_with_index.to_h
        lines = ["des (#{states.fetch(lts.initial)},#{lts.transitions.length},#{states.length})"]
        lts.transitions.each do |transition|
          label = JSON.generate("#{transition.input}/#{transition.output}")
          lines << "(#{states.fetch(transition.from)},#{label},#{states.fetch(transition.to)})"
        end
        lines.join("\n") << "\n"
      end
    end

    module CounterexampleRSpec
      module_function

      def call(lts:, sequence:, subject_name:)
        expected = outputs(lts, sequence)
        <<~RUBY
          # frozen_string_literal: true

          require "bparity"
          load ENV.fetch("BPARITY_ADAPTER")

          RSpec.describe "F3 distinguishing sequence for #{subject_name}" do
            it "matches the learned legacy model for #{sequence.join(' -> ')}" do
              binding = Bparity.adapter_definition.subjects.fetch(#{subject_name.inspect})
              subject = binding.build({})
              sequence = #{sequence.inspect}
              actual = sequence.map do |name|
                operation = binding.operations.fetch(name)
                begin
                  value = operation.invoke(subject, [], {})
                  Bparity::Formal::LtsEncoding.output({ "kind" => "return", "value" =>
                    Bparity::Recording::Serializer.dump(operation.map_return(value)) })
                rescue StandardError => error
                  Bparity::Formal::LtsEncoding.output({ "kind" => "raise", **operation.map_error(error) })
                end
              end
              expect(actual).to eq(#{expected.inspect})
            end
          end
        RUBY
      end

      def outputs(lts, sequence)
        state = lts.initial
        sequence.map do |input|
          transition = lts.step(state, input)
          state = transition.to
          transition.output
        end
      end
      private_class_method :outputs
    end

    class WMethod
      def initialize(lts)
        @lts = lts
      end

      def sequences(additional_states: 0)
        cover = transition_cover
        middle = (0..additional_states).flat_map { |length| @lts.alphabet.repeated_permutation(length).to_a }
        suffixes = characterization_set
        cover.product(middle, suffixes).map(&:flatten).uniq.sort_by { |sequence| [sequence.length, sequence] }
      end

      private

      def transition_cover
        paths = state_paths
        (paths.values + @lts.transitions.map { |transition| paths.fetch(transition.from) + [transition.input] }).uniq
      end

      def state_paths
        paths = { @lts.initial => [] }
        queue = [@lts.initial]
        until queue.empty?
          state = queue.shift
          @lts.outgoing(state).each do |transition|
            next if paths.key?(transition.to)

            paths[transition.to] = paths.fetch(state) + [transition.input]
            queue << transition.to
          end
        end
        paths
      end

      def characterization_set
        pairs = @lts.states.combination(2)
        sequences = pairs.filter_map { |left, right| distinguish(left, right) }
        sequences.empty? ? [[]] : sequences.uniq
      end

      def distinguish(left, right)
        queue = [[left, right, []]]
        visited = {}
        until queue.empty?
          state_a, state_b, path = queue.shift
          next if visited[[state_a, state_b]]

          visited[[state_a, state_b]] = true
          @lts.alphabet.each do |input|
            transition_a = @lts.step(state_a, input)
            transition_b = @lts.step(state_b, input)
            return path + [input] unless transition_a && transition_b
            return path + [input] unless transition_a.output == transition_b.output

            queue << [transition_a.to, transition_b.to, path + [input]]
          end
        end
        nil
      end
    end
  end
end
