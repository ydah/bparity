# frozen_string_literal: true

module Bparity
  module FormalCommands
    private

    def command_prove(argv)
      options = formal_options(argv)
      validate_formal_options!(options)
      options[:requires].each { |path| require File.expand_path(path) }
      bundle = SpecBundle::Loader.load(options[:spec])
      load File.expand_path(options[:adapter])
      result = case options[:level]
               when "f2" then run_f2(bundle, Bparity.adapter_definition, options)
               when "f3" then run_f3(bundle, Bparity.adapter_definition, options)
               else run_f4(bundle, Bparity.adapter_definition, options)
               end
      @out.puts(JSON.pretty_generate(result.to_h))
      result.success? ? 0 : 1
    end

    def formal_options(argv)
      options = { spec: ".bparity/spec_bundle.yml", adapter: ".bparity/adapter.rb", level: "f2",
                  size: 3, depth: 2, max_cases: 100_000, timebox: 300, requires: [], relation: "trace" }
      OptionParser.new do |opts|
        opts.on("--spec PATH") { |value| options[:spec] = value }
        opts.on("--adapter PATH") { |value| options[:adapter] = value }
        opts.on("--level LEVEL") { |value| options[:level] = value }
        opts.on("--scope SCOPE") { |value| parse_scope(value, options) }
        opts.on("--max-cases N", Integer) { |value| options[:max_cases] = value }
        opts.on("--timebox SECONDS", Integer) { |value| options[:timebox] = value }
        opts.on("--equivalence RELATION") { |value| options[:relation] = value }
        opts.on("--export-lts PREFIX") { |value| options[:export_lts] = value }
        opts.on("--counterexample-out PATH") { |value| options[:counterexample_out] = value }
        opts.on("--validate-translation") { options[:validate_translation] = true }
        opts.on("--old-source PATH") { |value| options[:old_source] = value }
        opts.on("--new-source PATH") { |value| options[:new_source] = value }
        opts.on("--old-method NAME") { |value| options[:old_method] = value }
        opts.on("--new-method NAME") { |value| options[:new_method] = value }
        opts.on("--types TYPES") { |value| options[:types] = value.split(",") }
        opts.on("--solver NAME") { |value| options[:solver] = value }
        opts.on("--require PATH") { |value| options[:requires] << value }
      end.parse!(argv)
      options
    end

    def validate_formal_options!(options)
      unless %w[f2 f3 f4].include?(options[:level])
        raise ConfigurationError, "Formal level #{options[:level]} is not available. Use f2, f3, or f4."
      end
      return unless options[:level] == "f4" && !options[:validate_translation]

      raise ConfigurationError, "F4 requires --validate-translation. Run F2 first and enable translation validation."
    end

    def run_f2(bundle, adapter, options)
      spec_subject = bundle.fetch("subjects").first
      operation_spec = spec_subject.fetch("operations").first
      binding = adapter.subjects.fetch(spec_subject.fetch("name"))
      operation = binding.operations.fetch(operation_spec.fetch("name"))
      old_class = Bparity.constantize(spec_subject.fetch("old_class"))
      domains = f2_domains(operation_spec, options)
      method_name = operation_spec.fetch("name").delete_prefix("#")
      old_callable = ->(*args) { old_class.new.public_send(method_name, *args) }
      new_callable = ->(*args) { operation.invoke(binding.build({}), args, {}) }
      runner = build_f2_runner(old_callable, new_callable, domains, operation, options)
      target = binding.build({})
      monitored_class = target.is_a?(Module) ? target.singleton_class : target.class
      result, violations = Formal::Assumptions::WorldFreeze.new([old_class, monitored_class]).check { runner.run }
      return result if violations.empty?

      Formal::Result.new(level: :f2, verdict: :inconclusive, scope: result.scope,
                         assumptions: result.assumptions, out_of_scope: result.out_of_scope,
                         details: { "assumption_violations" => violations })
    end

    def f2_domains(operation_spec, options)
      operation_spec.fetch("params", []).map do |param|
        type = param.fetch("types", ["String"]).first
        observed = param.fetch("observed_values", [])
        alphabet = observed.grep(String).flat_map(&:chars).uniq.first(8)
        Formal::ValueEnumerator.new(size: options[:size], depth: options[:depth],
                                    alphabet: alphabet.empty? ? %w[a b] : alphabet, observed:).values(type) + [nil]
      end
    end

    def build_f2_runner(old_callable, new_callable, domains, operation, options)
      Formal::ExhaustiveRunner.new(old_callable:, new_callable:, domains:, size: options[:size],
                                   depth: options[:depth], assumptions: %i[h1 h3 h7],
                                   max_cases: options[:max_cases], timebox: options[:timebox],
                                   new_error_mapper: operation.method(:map_error))
    end

    def parse_scope(value, options)
      value.split(",").each do |entry|
        key, number = entry.split("=", 2)
        raise ConfigurationError, "Invalid scope #{entry}. Use size=N,depth=N." unless %w[size depth].include?(key)

        options[key.to_sym] = Integer(number, 10)
      end
    rescue ArgumentError
      raise ConfigurationError, "Invalid scope #{value}. Use size=N,depth=N."
    end

    def run_f3(bundle, adapter, options)
      spec_subject = bundle.fetch("subjects").find { |subject| subject["lts_ref"] }
      unless spec_subject
        raise ConfigurationError, "The Spec Bundle has no stateful subject. Record with a state projection first."
      end

      old_data = bundle.fetch("lts").find { |model| model["id"] == spec_subject["lts_ref"] }
      old_lts = Formal::LTS.from_h(old_data)
      binding = adapter.subjects.fetch(spec_subject.fetch("name"))
      unless binding.state_projection
        raise ConfigurationError,
              "Adapter subject #{binding.name} needs a state block for F3."
      end

      operations = binding.operations.to_h { |name, operation| [name, observed_operation(operation)] }
      learned = Formal::ActiveLearner.new(factory: -> { binding.build({}) },
                                          state_projection: binding.state_projection, operations:).learn
      export_lts(options[:export_lts], old_lts, learned.lts) if options[:export_lts]
      result = Formal::LtsEquivalence.new.compare(old_lts, learned.lts, relation: options[:relation],
                                                                        exact: learned.complete)
      write_lts_counterexample(result, options, old_lts, spec_subject)
      result
    end

    def observed_operation(operation)
      lambda do |subject|
        value = operation.invoke(subject, [], {})
        Formal::ObservedOutput.new({ "kind" => "return",
                                     "value" => Recording::Serializer.dump(operation.map_return(value)) })
      rescue StandardError => e
        Formal::ObservedOutput.new({ "kind" => "raise", **operation.map_error(e) })
      end
    end

    def write_lts_counterexample(result, options, old_lts, spec_subject)
      return unless result.counterexample && options[:counterexample_out]

      spec = Formal::CounterexampleRSpec.call(lts: old_lts,
                                              sequence: result.counterexample.fetch("sequence"),
                                              subject_name: spec_subject.fetch("name"))
      File.write(options[:counterexample_out], spec)
    end

    def export_lts(prefix, old_lts, new_lts)
      File.write("#{prefix}_old.aut", Formal::AldebaranExporter.call(old_lts))
      File.write("#{prefix}_new.aut", Formal::AldebaranExporter.call(new_lts))
    end

    def run_f4(bundle, adapter, options)
      validate_f4_options!(options)
      subject_spec = bundle.fetch("subjects").first
      operation_spec = subject_spec.fetch("operations").first
      binding = adapter.subjects.fetch(subject_spec.fetch("name"))
      operation = binding.operations.fetch(operation_spec.fetch("name"))
      old_class = Bparity.constantize(subject_spec.fetch("old_class"))
      translator = Formal::Deductive::RubyToSmt.new
      old_translation = translator.translate_file(options[:old_source], options[:old_method],
                                                  parameter_types: options[:types])
      new_translation = translator.translate_file(options[:new_source], options[:new_method],
                                                  parameter_types: options[:types])
      inputs = f4_inputs(options[:types], options)
      old_callable = ->(*args) { old_class.new.public_send(options[:old_method], *args) }
      new_callable = ->(*args) { operation.invoke(binding.build({}), args, {}) }
      Formal::Deductive::Runner.new(old_translation:, new_translation:, old_callable:, new_callable:,
                                    validation_inputs: inputs,
                                    solver: Formal::Deductive::Z3.new(timeout: options[:timebox])).run
    end

    def validate_f4_options!(options)
      required = %i[old_source new_source old_method new_method types]
      missing = required.reject { |key| options[key] }
      unless missing.empty?
        raise ConfigurationError,
              "F4 is missing #{missing.join(', ')}. Provide both sources, method names, and --types."
      end
      return unless options[:solver] && options[:solver] != "z3"

      raise ConfigurationError, "Unsupported F4 solver #{options[:solver]}. Use z3."
    end

    def f4_inputs(types, options)
      domains = types.map do |type|
        Formal::ValueEnumerator.new(size: options[:size], depth: options[:depth]).values(type)
      end
      return [[]] if domains.empty?

      domains.first.product(*domains.drop(1)).first(options[:max_cases])
    end
  end
end
