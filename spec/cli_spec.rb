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

  it "refuses to prove F4 after truncated translation validation" do
    cli = described_class.new(out: StringIO.new, err: StringIO.new)
    expect { cli.send(:f4_inputs, ["Integer"], size: 2, depth: 1, max_cases: 4) }
      .to raise_error(Bparity::ConfigurationError, /does not support truncated translation validation/)
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
