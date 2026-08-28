# frozen_string_literal: true

require "bparity/cli"
require "stringio"
require "tmpdir"

RSpec.describe Bparity::CLI do
  it "prints English errors with a next action" do
    output = StringIO.new
    status = described_class.start(["unknown"], out: StringIO.new, err: output)

    expect(status).to eq(2)
    expect(output.string).to include("unknown command", "Run `bparity help`")
    expect(output.string).not_to match(/[ぁ-んァ-ヶ一-龠]/)
  end

  it "refuses F4 without translation validation" do
    output = StringIO.new
    status = described_class.start(%w[prove --level f4], out: StringIO.new, err: output)

    expect(status).to eq(2)
    expect(output.string).to include("F4 requires --validate-translation")
  end

  it "rejects invalid formal limits before running a proof" do
    cli = described_class.new(out: StringIO.new, err: StringIO.new)
    options = { level: "f2", size: -1, depth: 1, max_cases: 1, timebox: 1, state_limit: nil }

    expect { cli.send(:validate_formal_options!, options) }
      .to raise_error(Bparity::ConfigurationError, /Formal limits are invalid/)
  end

  it "refuses to prove F4 after truncated translation validation" do
    cli = described_class.new(out: StringIO.new, err: StringIO.new)
    expect { cli.send(:f4_inputs, ["Integer"], size: 2, depth: 1, max_cases: 4) }
      .to raise_error(Bparity::ConfigurationError, /does not support truncated translation validation/)
  end

  it "refuses an ambiguous formal target instead of proving only the first operation" do
    bundle = { "subjects" => [{ "name" => "One", "operations" => [{ "name" => "#a" }] },
                              { "name" => "Two", "operations" => [{ "name" => "#b" }] }] }
    cli = described_class.new(out: StringIO.new, err: StringIO.new)

    expect { cli.send(:select_formal_operation, bundle, {}) }
      .to raise_error(Bparity::ConfigurationError, /Select one formal subject/)
  end

  it "refuses to check only the first stateful subject" do
    bundle = { "subjects" => [{ "name" => "One", "lts_ref" => "one" },
                              { "name" => "Two", "lts_ref" => "two" }],
               "lts" => [{ "id" => "one" }, { "id" => "two" }] }
    cli = described_class.new(out: StringIO.new, err: StringIO.new)

    expect { cli.send(:select_f3_subject, bundle, {}) }
      .to raise_error(Bparity::ConfigurationError, /Select one F3 subject/)
  end

  it "promotes invariants only after an exhaustive successful F2 result" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "spec.yml")
      bundle = { "spec_bundle_version" => 2, "subjects" => [{ "name" => "Value", "operations" => [{
        "name" => "#call", "examples" => [],
        "invariants" => [{ "id" => "inv-1", "expr" => "return != nil", "formal_level" => "F0" }]
      }] }] }
      Bparity::SpecBundle::Writer.write(path, bundle)
      result = Bparity::Formal::Result.new(
        level: :f2, verdict: :no_difference_found,
        scope: Bparity::Formal::Scope.new(size: 1, depth: 1, cases: 1, exhaustive: true),
        assumptions: [:h1], out_of_scope: []
      )
      cli = described_class.new(out: StringIO.new, err: StringIO.new)
      options = { level: "f2", promote_invariants: true, spec: path, subject: "Value", operation: "#call" }

      cli.send(:promote_f2_invariants, bundle, options, result)
      expect(Bparity::SpecBundle::Loader.load(path).dig("subjects", 0, "operations", 0, "invariants", 0,
                                                        "formal_level")).to eq("F2")
    end
  end

  it "enumerates every declared F2 parameter type and rejects an unknown domain" do
    cli = described_class.new(out: StringIO.new, err: StringIO.new)
    options = { size: 1, depth: 1 }
    domains = cli.send(:f2_domains, { "params" => [{ "name" => "value",
                                                     "types" => %w[Integer String] }] }, options)
    expect(domains.first).to include(-1, 0, 1, "", "a", nil)
    expect { cli.send(:f2_domains, { "params" => [{ "name" => "value", "types" => [] }] }, options) }
      .to raise_error(Bparity::ConfigurationError, /has no inferred type/)
  end

  it "enumerates recorded user-defined objects through the CLI domain path" do
    stub_const("DomainPoint", Class.new do
      attr_reader :x

      def initialize(value) = @x = value
    end)
    serialized = Bparity::Recording::Serializer.dump(DomainPoint.new(1))
    operation = { "params" => [{ "name" => "point", "types" => ["DomainPoint"],
                                 "observed_values" => [serialized] }] }

    domain = described_class.new(out: StringIO.new, err: StringIO.new)
                            .send(:f2_domains, operation, size: 1, depth: 1).first
    expect(domain.grep(DomainPoint).map(&:x)).to contain_exactly(1, nil)
  end

  it "proves declared F2 contracts without loading the legacy class" do
    stub_const("ContractReplacement", Class.new { def call(value) = value })
    bundle = { "subjects" => [{ "name" => "Value", "old_class" => "UnavailableLegacy",
                                "operations" => [{ "name" => "#call",
                                                   "params" => [{ "name" => "value", "types" => ["Integer"],
                                                                  "observed_values" => [0] }],
                                                   "preconditions" => [{ "id" => "input",
                                                                         "expr" => "args[0] != nil" }],
                                                   "invariants" => [{ "id" => "same",
                                                                      "expr" => "return == args[0]" }],
                                                   "examples" => [] }] }] }
    adapter = Bparity.adapter do
      subject "Value" do
        construct { ContractReplacement.new }
        operation("#call")
      end
    end
    options = { subject: "Value", operation: "#call", size: 1, depth: 1, max_cases: 100,
                timebox: 10 }

    result = described_class.new(out: StringIO.new, err: StringIO.new).send(:run_f2, bundle, adapter, options)
    expect(result.to_h).to include("verdict" => "no_difference_found",
                                   "out_of_scope" => include("legacy behavior beyond declared contracts"))
  end

  it "rejects an unusable legacy construction instead of reporting a behavior difference" do
    stub_const("NeedsConfiguration", Class.new do
      def initialize(required); end
      def call(value) = value
    end)
    cli = described_class.new(out: StringIO.new, err: StringIO.new)
    expect { cli.send(:validate_legacy_operation!, NeedsConfiguration, "call") }
      .to raise_error(Bparity::ConfigurationError, /cannot be constructed without arguments/)
  end

  it "discovers Ruby calls for an explicit target without C calls" do
    stub_const("DiscoveryTarget", Class.new do
      def called = :ok
      def not_called = :ok
    end)
    Dir.mktmpdir do |dir|
      script = File.join(dir, "exercise.rb")
      File.write(script, "DiscoveryTarget.new.called\n")
      output = StringIO.new

      status = described_class.start(["discover", "--target", "DiscoveryTarget", script], out: output,
                                                                                          err: StringIO.new)

      expect(status).to eq(0)
      expect(output.string).to include("methods :called")
      expect(output.string).not_to include(":not_called")
    end
  end

  it "generates an adapter skeleton from a Specification Bundle" do
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "spec.yml")
      Bparity::SpecBundle::Writer.write(spec, "spec_bundle_version" => 2, "subjects" => [
                                          { "name" => "Widget",
                                            "operations" => [{ "name" => "#fetch", "examples" => [] }] }
                                        ])
      output = StringIO.new
      Dir.chdir(dir) do
        expect(described_class.start(["init", "--from-spec", spec], out: output, err: StringIO.new)).to eq(0)
      end

      expect(File.read(File.join(dir, ".bparity/adapter.rb"))).to include('subject "Widget"',
                                                                          'operation "#fetch"')
    end
  end

  it "rejects unknown report formats before invoking the replacement" do
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "spec.yml")
      adapter = File.join(dir, "adapter.rb")
      Bparity::SpecBundle::Writer.write(spec, "spec_bundle_version" => 2, "subjects" => [
                                          { "name" => "Unused", "operations" => [] }
                                        ])
      File.write(adapter, "Bparity.adapter { }\n")
      error = StringIO.new

      status = described_class.start(["verify", "--spec", spec, "--adapter", adapter, "--format", "object_id"],
                                     out: StringIO.new, err: error)
      expect(status).to eq(2)
      expect(error.string).to include("Unknown report format", "Use markdown, json, junit, or html")
    end
  end

  it "builds a reviewable and verifiable bundle from static assertions only" do
    Dir.mktmpdir do |dir|
      test_path = File.join(dir, "widget_spec.rb")
      bundle_path = File.join(dir, "static.yml")
      File.write(test_path, <<~RUBY)
        RSpec.describe "StaticWidget" do
          it "fetches a value" do
            expect(subject.fetch("key")).to eq("value")
          end
        end
      RUBY

      status = described_class.start(["synthesize", "--static-only", "--tests", test_path,
                                      "--out", bundle_path], out: StringIO.new, err: StringIO.new)
      bundle = Bparity::SpecBundle::Loader.load(bundle_path)
      example = bundle.dig("subjects", 0, "operations", 0, "examples", 0)

      expect(status).to eq(0)
      expect(example).to include("provenance_level" => "C", "formal_level" => "F0")
      expect(bundle.fetch("gaps")).to include(include("kind" => "no_runtime_recording"))

      replacement = Class.new { def fetch(_key) = "value" }
      stub_const("StaticReplacement", replacement)
      adapter = Bparity.adapter do
        subject "StaticWidget" do
          construct { StaticReplacement.new }
          operation("#fetch")
        end
      end
      expect(Bparity::Verification::Runner.new(bundle:, adapter:).run.map(&:status)).to eq([:pass])
    end
  end
end
