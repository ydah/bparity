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
