# frozen_string_literal: true

require "shellwords"

module Bparity
  module VerificationCommands
    private

    def command_verify(argv)
      options = verify_options(argv)
      validate_verify_options!(options)
      options[:requires].each { |path| require File.expand_path(path) }
      bundle = SpecBundle::Loader.load(options[:spec])
      adapter = load_verify_adapter(bundle, options[:adapter], options[:adapter_explicit])
      results = options[:runners].flat_map { |runner| run_verify_runner(runner, bundle, adapter, options) }
      write_verification_report(results, bundle, options)
      verify_success?(results, options[:fail_under]) ? 0 : 1
    end

    def verify_options(argv)
      options = { spec: ".bparity/spec_bundle.yml", adapter: ".bparity/adapter.rb", format: "markdown",
                  runners: ["replay"], fail_under: 100.0, size: 3, depth: 2, max_cases: 1_000,
                  timebox: 300, state_limit: 500, relation: "trace", requires: [] }
      OptionParser.new do |opts|
        add_verify_core_options(opts, options)
        add_verify_generation_options(opts, options)
      end.parse!(argv)
      options
    end

    def add_verify_core_options(parser, options)
      parser.on("--spec PATH") { |value| options[:spec] = value }
      parser.on("--adapter PATH") do |value|
        options[:adapter] = value
        options[:adapter_explicit] = true
      end
      parser.on("--mode MODE") { |value| options[:mode] = value }
      parser.on("--runners LIST") { |value| options[:runners] = value.split(",") }
      parser.on("--fail-under PERCENT", Float) { |value| options[:fail_under] = value }
      parser.on("--format FORMAT") { |value| options[:format] = value }
      parser.on("--out PATH") { |value| options[:out] = value }
      parser.on("--require PATH") { |value| options[:requires] << value }
    end

    def add_verify_generation_options(parser, options)
      parser.on("--scope SCOPE") { |value| parse_scope(value, options) }
      parser.on("--max-cases N", Integer) { |value| options[:max_cases] = value }
      parser.on("--timebox SECONDS", Integer) { |value| options[:timebox] = value }
      parser.on("--state-limit N", Integer) { |value| options[:state_limit] = value }
      parser.on("--equivalence RELATION") { |value| options[:relation] = value }
      parser.on("--subject NAME") { |value| options[:subject] = value }
      parser.on("--operation NAME") { |value| options[:operation] = value }
      parser.on("--old-command COMMAND") { |value| options[:old_command] = Shellwords.split(value) }
      parser.on("--new-command COMMAND") { |value| options[:new_command] = Shellwords.split(value) }
    end

    def validate_verify_options!(options)
      unless Reporting::Reporter::FORMATS.include?(options[:format])
        raise ConfigurationError,
              "Unknown report format #{options[:format]}. Use markdown, json, junit, or html."
      end
      allowed = %w[replay property model differential]
      unknown = options[:runners] - allowed
      unless unknown.empty?
        raise ConfigurationError,
              "Unknown verification runner #{unknown.join(', ')}. Use replay, property, model, or differential."
      end
      raise ConfigurationError, "At least one verification runner is required." if options[:runners].empty?
      unless (0.0..100.0).cover?(options[:fail_under])
        raise ConfigurationError, "Verification threshold must be between 0 and 100."
      end
      unless options.values_at(:size, :depth).all? { |value| value >= 0 } &&
             options.values_at(:max_cases, :timebox, :state_limit).all?(&:positive?)
        raise ConfigurationError,
              "Verification limits are invalid. Use non-negative size/depth and positive case, time, and state limits."
      end
      return unless options[:runners].include?("differential") &&
                    (!options[:old_command] || !options[:new_command])

      raise ConfigurationError,
            "Differential verification requires --old-command and --new-command. " \
            "Each command must read JSON from stdin."
    end

    def load_verify_adapter(bundle, path, explicit)
      if File.exist?(path)
        Bparity.reset!
        load File.expand_path(path)
        return Bparity.adapter_definition || raise(ConfigurationError,
                                                   "The adapter file did not call Bparity.adapter.")
      end
      if explicit
        raise ConfigurationError,
              "Adapter file #{path} was not found. Correct the path or omit --adapter for direct replay."
      end

      direct_adapter(bundle)
    end

    def direct_adapter(bundle)
      Adapter::Definition.new.tap do |definition|
        bundle.fetch("subjects").each do |spec_subject|
          name = spec_subject.fetch("name")
          definition.subject(name) do
            construct do
              target = Bparity.constantize(name)
              target.is_a?(Class) ? target.new : target
            end
            spec_subject.fetch("operations").each do |spec_operation|
              operation(spec_operation.fetch("name"))
            end
          end
        end
      end
    end

    def run_verify_runner(name, bundle, adapter, options)
      case name
      when "replay" then Verification::Runner.new(bundle:, adapter:, mode: options[:mode]).run
      when "property" then run_property_verification(bundle, adapter, options)
      when "model" then [formal_verification_result(run_f3(bundle, adapter, options), "model")]
      else run_differential_verification(bundle, options)
      end
    end

    def run_property_verification(bundle, adapter, options)
      checks = bundle.fetch("subjects").flat_map do |subject|
        subject.fetch("operations").filter_map do |operation_spec|
          contracts = operation_spec.fetch("postconditions", []) + operation_spec.fetch("invariants", [])
          next if contracts.empty?

          binding, operation = formal_binding(adapter, subject, operation_spec)
          callable = lambda do |*args|
            operation.map_return(operation.invoke(binding.build({}), args, {}))
          end
          counterexample = Formal::PropertyRunner.new(
            callable:, invariants: contracts, inputs: generated_inputs(operation_spec, options),
            preconditions: operation_spec.fetch("preconditions", [])
          ).run
          property_result(subject, operation_spec, counterexample)
        end
      end
      return checks unless checks.empty?

      raise ConfigurationError,
            "Property verification found no contracts. Synthesize invariants or select the replay runner."
    end

    def run_differential_verification(bundle, options)
      subject, operation = select_formal_operation(bundle, options)
      differences = Formal::DifferentialRunner.new(
        old_command: options[:old_command], new_command: options[:new_command],
        inputs: generated_inputs(operation, options)
      ).run
      if differences.empty?
        return [Verification::Result.new(id: "differential:#{subject['name']}#{operation['name']}",
                                         status: :pass, description: "Generated differential inputs matched",
                                         differences: [], provenance: { "runner" => "differential" })]
      end

      differences.each_with_index.map do |difference, index|
        Verification::Result.new(id: "differential:#{subject['name']}#{operation['name']}:#{index + 1}",
                                 status: :fail, description: "Generated differential input differed",
                                 differences: difference.fetch("differences"),
                                 provenance: { "runner" => "differential",
                                               "input" => Recording::Serializer.dump(difference.fetch("input")) })
      end
    end

    def generated_inputs(operation, options)
      domains = operation.fetch("params", []).map { |param| generated_domain(param, options) }
      Enumerator.new do |items|
        if domains.empty?
          items << []
        else
          domains.first.product(*domains.drop(1)) { |input| items << input }
        end
      end.take(options[:max_cases])
    end

    def generated_domain(param, options)
      observed = param.fetch("observed_values", []).map { |value| Recording::Serializer.load(value) }
      alphabet = observed.grep(String).flat_map(&:chars).uniq.first(8)
      generator = Formal::InputGenerator.new(size: options[:size], depth: options[:depth], observed:,
                                             alphabet: alphabet.empty? ? %w[a b] : alphabet)
      types = param.fetch("types", [])
      if types.empty?
        raise ConfigurationError,
              "Property parameter #{param['name']} has no inferred type. Record values or add an input domain."
      end
      types.flat_map { |type| generator.values(type) }.uniq
    end

    def property_result(subject, operation, counterexample)
      differences = []
      if counterexample
        differences = counterexample.fetch("violations").map do |violation|
          { "path" => "$.contracts.#{violation['id']}", "expected" => true,
            "actual" => violation["error"] || false }
        end
      end
      Verification::Result.new(id: "property:#{subject['name']}#{operation['name']}",
                               status: differences.empty? ? :pass : :fail,
                               description: "Generated property inputs satisfy declared contracts",
                               differences:, provenance: { "runner" => "property",
                                                           "input" => Recording::Serializer.dump(
                                                             counterexample&.fetch("input", nil)
                                                           ) })
    end

    def formal_verification_result(result, name)
      skipped = result.details["skipped"]
      differences = if result.success? || skipped
                      []
                    else
                      [{ "path" => "$.#{name}", "expected" => "no difference",
                         "actual" => result.counterexample || result.details }]
                    end
      status = if skipped then :skipped
               elsif differences.empty? then :pass
               else :fail
               end
      Verification::Result.new(id: name, status:, description: skipped || "Finite-state model conformance",
                               differences:, provenance: { "runner" => name, "formal_result" => result.to_h })
    end

    def write_verification_report(results, bundle, options)
      report = Reporting::Reporter.new(results, bundle:).public_send(options[:format])
      return @out.puts(report) unless options[:out]

      FileUtils.mkdir_p(File.dirname(options[:out]))
      File.write(options[:out], report)
    end

    def verify_success?(results, threshold)
      eligible = results.reject { |result| result.status == :skipped }
      return false if eligible.empty? || eligible.any? { |result| result.status == :fail }

      100.0 * eligible.count { |result| %i[pass waived].include?(result.status) } / eligible.length >= threshold
    end
  end
end
