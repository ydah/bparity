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
                                          { "name" => "Widget", "operations" => [{ "name" => "#fetch" }] }
                                        ])
      output = StringIO.new
      Dir.chdir(dir) do
        expect(described_class.start(["init", "--from-spec", spec], out: output, err: StringIO.new)).to eq(0)
      end

      expect(File.read(File.join(dir, ".bparity/adapter.rb"))).to include('subject "Widget"',
                                                                          'operation "#fetch"')
    end
  end
end
