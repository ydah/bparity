# frozen_string_literal: true

require "optparse"

module Bparity
  class CLI
    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(out:, err:).start(argv)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def start(argv)
      command = argv.shift
      return help if command.nil? || %w[-h --help help].include?(command)

      send("command_#{command.tr('-', '_')}", argv)
    rescue OptionParser::ParseError, Error => e
      @err.puts("Error: #{e.message}")
      2
    rescue NoMethodError => e
      raise unless e.name.to_s.start_with?("command_")

      @err.puts("Error: unknown command #{command.inspect}. Run `bparity help` for usage.")
      2
    end

    private

    def command_record(argv)
      options = { boundary: ".bparity/boundary.rb", out: ".bparity/corpus/behavior.jsonl", requires: [] }
      parser = OptionParser.new do |opts|
        opts.on("--boundary PATH") { |value| options[:boundary] = value }
        opts.on("--out PATH") { |value| options[:out] = value }
        opts.on("--require PATH") { |value| options[:requires] << value }
        opts.on("--driver DRIVER") { |value| options[:driver] = value }
      end
      parser.parse!(argv)
      options[:requires].each { |path| require File.expand_path(path) }
      load File.expand_path(options[:boundary])
      boundary = Bparity.boundary_definition || raise(ConfigurationError,
                                                      "The boundary file did not call Bparity.boundary.")
      writer = Corpus::Writer.new(options[:out])
      Recording::Recorder.new(boundary:, writer:).install!
      status = run_driver(options[:driver] || boundary.driver_config&.fetch(:name, nil), argv, boundary)
      writer.close
      status
    end

    def command_synthesize(argv)
      options = { corpus: ".bparity/corpus/behavior.jsonl", out: ".bparity/spec_bundle.yml", tests: [], source: [] }
      OptionParser.new do |opts|
        opts.on("--corpus PATH") { |value| options[:corpus] = value }
        opts.on("--out PATH") { |value| options[:out] = value }
        opts.on("--tests GLOB") { |value| options[:tests].concat(Dir.glob(value)) }
        opts.on("--source GLOB") { |value| options[:source].concat(Dir.glob(value)) }
      end.parse!(argv)
      extractor = Synthesis::StaticExtractor.new
      bundle = Synthesis::Synthesizer.new(records: Corpus::Reader.new(options[:corpus]).to_a,
                                          static_examples: extractor.extract_tests(options[:tests]),
                                          source_facts: extractor.extract_source(options[:source])).call
      SpecBundle::Writer.write(options[:out], bundle)
      @out.puts("Wrote #{options[:out]}")
      0
    end

    def command_verify(argv)
      options = { spec: ".bparity/spec_bundle.yml", adapter: ".bparity/adapter.rb", format: "markdown" }
      OptionParser.new do |opts|
        opts.on("--spec PATH") { |value| options[:spec] = value }
        opts.on("--adapter PATH") { |value| options[:adapter] = value }
        opts.on("--mode MODE") { |value| options[:mode] = value }
        opts.on("--format FORMAT") { |value| options[:format] = value }
        opts.on("--out PATH") { |value| options[:out] = value }
        opts.on("--require PATH") { |value| require File.expand_path(value) }
      end.parse!(argv)
      bundle = SpecBundle::Loader.load(options[:spec])
      load File.expand_path(options[:adapter])
      adapter = Bparity.adapter_definition || raise(ConfigurationError,
                                                    "The adapter file did not call Bparity.adapter.")
      runner = Verification::Runner.new(bundle:, adapter:, mode: options[:mode])
      results = runner.run
      report = Reporting::Reporter.new(results, bundle:).public_send(options[:format])
      options[:out] ? File.write(options[:out], report) : @out.puts(report)
      runner.success? ? 0 : 1
    end

    def command_diff(argv)
      raise ConfigurationError, "Usage: bparity diff OLD.yml NEW.yml" unless argv.length == 2

      old_bundle, new_bundle = argv.map { |path| SpecBundle::Loader.load(path, verify_checksum: false) }
      differences = Verification::Differ.call(old_bundle, new_bundle)
      @out.puts(JSON.pretty_generate(differences))
      differences.empty? ? 0 : 1
    end

    def command_explain(argv)
      options = { spec: ".bparity/spec_bundle.yml" }
      OptionParser.new { |opts| opts.on("--spec PATH") { |value| options[:spec] = value } }.parse!(argv)
      id = argv.shift || raise(ConfigurationError, "Usage: bparity explain ID [--spec PATH]")
      bundle = SpecBundle::Loader.load(options[:spec])
      example = bundle.fetch("subjects").flat_map { |subject| subject.fetch("operations") }
                      .flat_map { |operation| operation.fetch("examples") }.find { |item| item["id"] == id }
      raise ConfigurationError, "Specification item #{id} was not found. Check the ID in the report." unless example

      @out.puts(JSON.pretty_generate(example))
      0
    end

    def command_assumptions(argv)
      options = { spec: ".bparity/spec_bundle.yml" }
      OptionParser.new { |opts| opts.on("--spec PATH") { |value| options[:spec] = value } }.parse!(argv)
      @out.puts(JSON.pretty_generate(SpecBundle::Loader.load(options[:spec]).fetch("verification_assumptions", [])))
      0
    end

    def command_prove(argv)
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
        opts.on("--require PATH") { |value| options[:requires] << value }
      end.parse!(argv)
      unless %w[f2 f3].include?(options[:level])
        raise ConfigurationError, "Formal level #{options[:level]} is not available through this runner. Use f2 or f3."
      end

      options[:requires].each { |path| require File.expand_path(path) }
      bundle = SpecBundle::Loader.load(options[:spec])
      load File.expand_path(options[:adapter])
      result = if options[:level] == "f2"
                 run_f2(bundle, Bparity.adapter_definition, options)
               else
                 run_f3(bundle, Bparity.adapter_definition, options)
               end
      @out.puts(JSON.pretty_generate(result.to_h))
      result.success? ? 0 : 1
    end

    def command_init(argv)
      options = {}
      OptionParser.new do |opts|
        opts.on("--timecapsule") { options[:timecapsule] = true }
      end.parse!(argv)
      FileUtils.mkdir_p(".bparity")
      write_unless_exists(".bparity/boundary.rb", "Bparity.boundary do\n  # observe \"Legacy::Class\"\nend\n")
      adapter = "Bparity.adapter(spec: \".bparity/spec_bundle.yml\") do\n  " \
                "# subject \"Class\" do\n  # end\nend\n"
      write_unless_exists(".bparity/adapter.rb", adapter)
      if options[:timecapsule]
        FileUtils.mkdir_p(".bparity/timecapsule")
        write_unless_exists(".bparity/timecapsule/Dockerfile", timecapsule)
      end
      @out.puts("Initialized .bparity")
      0
    end

    def run_driver(driver, argv, boundary)
      case driver&.to_sym
      when :rspec
        require "rspec/core"
        files = argv.empty? ? Dir.glob(boundary.driver_config&.fetch(:files, "spec/**/*_spec.rb")) : argv
        RSpec::Core::Runner.run(files, @err, @out)
      when :minitest
        require "minitest"
        (argv.empty? ? Dir.glob(boundary.driver_config&.fetch(:files, "test/**/*_test.rb")) : argv).each do |file|
          require File.expand_path(file)
        end
        Minitest.run ? 0 : 1
      else
        raise ConfigurationError, "A driver is required. Add `driver :rspec` or `driver :minitest` to the boundary."
      end
    rescue LoadError
      raise ConfigurationError, "The #{driver} driver is not installed. Add it to the legacy environment and try again."
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
        raise ConfigurationError,
              "The Spec Bundle has no stateful subject. Record with a state projection first."
      end

      old_data = bundle.fetch("lts").find { |model| model["id"] == spec_subject["lts_ref"] }
      old_lts = Formal::LTS.from_h(old_data)
      binding = adapter.subjects.fetch(spec_subject.fetch("name"))
      unless binding.state_projection
        raise ConfigurationError, "Adapter subject #{binding.name} needs a state block for F3."
      end

      operations = binding.operations.to_h do |name, operation|
        callable = lambda do |subject|
          value = operation.invoke(subject, [], {})
          Formal::ObservedOutput.new({ "kind" => "return",
                                       "value" => Recording::Serializer.dump(operation.map_return(value)) })
        rescue StandardError => e
          Formal::ObservedOutput.new({ "kind" => "raise", **operation.map_error(e) })
        end
        [name, callable]
      end
      learned = Formal::ActiveLearner.new(factory: -> { binding.build({}) },
                                          state_projection: binding.state_projection, operations:).learn
      export_lts(options[:export_lts], old_lts, learned.lts) if options[:export_lts]
      result = Formal::LtsEquivalence.new.compare(old_lts, learned.lts, relation: options[:relation],
                                                                        exact: learned.complete)
      if result.counterexample && options[:counterexample_out]
        spec = Formal::CounterexampleRSpec.call(lts: old_lts,
                                                sequence: result.counterexample.fetch("sequence"),
                                                subject_name: spec_subject.fetch("name"))
        File.write(options[:counterexample_out], spec)
      end
      result
    end

    def export_lts(prefix, old_lts, new_lts)
      File.write("#{prefix}_old.aut", Formal::AldebaranExporter.call(old_lts))
      File.write("#{prefix}_new.aut", Formal::AldebaranExporter.call(new_lts))
    end

    def write_unless_exists(path, content)
      raise ConfigurationError, "#{path} already exists. Move it aside before running init." if File.exist?(path)

      File.write(path, content)
    end

    def timecapsule
      <<~DOCKERFILE
        FROM ruby:3.1-slim
        COPY vendor/cache/ vendor/cache/
        COPY Gemfile Gemfile.lock ./
        RUN bundle install --local
        COPY . .
        CMD ["bundle", "exec", "bparity", "record"]
      DOCKERFILE
    end

    def help
      @out.puts <<~HELP
        Usage: bparity COMMAND [options]

        Commands: init, record, synthesize, verify, diff, explain, assumptions, prove, adequacy
      HELP
      0
    end
  end
end
