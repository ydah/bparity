# frozen_string_literal: true

require "tmpdir"

RSpec.describe Bparity::SpecBundle do
  let(:bundle) do
    {
      "spec_bundle_version" => 2,
      "subjects" => [{ "name" => "Slug", "operations" => [] }]
    }
  end

  it "writes, validates, and detects edits" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bundle.yml")
      described_class::Writer.write(path, bundle)
      expect(described_class::Loader.load(path)).to include("checksum" => a_string_starting_with("sha256:"))

      edited = YAML.safe_load_file(path)
      edited["subjects"][0]["name"] = "Edited"
      File.write(path, YAML.dump(edited))
      expect { described_class::Loader.load(path) }.to raise_error(Bparity::InvalidBundleError, /checksum/)
    end
  end
end
