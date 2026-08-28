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

      edited.delete("checksum")
      File.write(path, YAML.dump(edited))
      expect { described_class::Loader.load(path) }.to raise_error(Bparity::InvalidBundleError, /no checksum/)
    end
  end

  it "rejects malformed nested data and duplicate example IDs" do
    malformed = {
      "spec_bundle_version" => 2,
      "subjects" => [{ "name" => "Slug", "operations" => [{ "name" => "#call", "examples" => [{}] }] }]
    }
    expect { described_class::Validator.validate!(malformed, verify_checksum: false) }
      .to raise_error(Bparity::InvalidBundleError, /each example needs/)

    example = { "id" => "ex-1", "provenance_level" => "A", "formal_level" => "F0",
                "provenance" => {}, "given" => {}, "expect" => {} }
    duplicated = {
      "spec_bundle_version" => 2,
      "subjects" => [{ "name" => "Slug", "operations" => [
        { "name" => "#one", "examples" => [example] },
        { "name" => "#two", "examples" => [example.dup] }
      ] }]
    }
    expect { described_class::Validator.validate!(duplicated, verify_checksum: false) }
      .to raise_error(Bparity::InvalidBundleError, /example IDs must be unique/)

    malformed_subject = { "spec_bundle_version" => 2, "subjects" => ["not an object"] }
    expect { described_class::Validator.validate!(malformed_subject, verify_checksum: false) }
      .to raise_error(Bparity::InvalidBundleError, /each subject needs/)

    missing_lts = { "spec_bundle_version" => 2,
                    "subjects" => [{ "name" => "Stateful", "lts_ref" => "missing", "operations" => [] }] }
    expect { described_class::Validator.validate!(missing_lts, verify_checksum: false) }
      .to raise_error(Bparity::InvalidBundleError, /LTS references are missing models/)

    malformed_lts = { "spec_bundle_version" => 2,
                      "subjects" => [{ "name" => "Stateful", "lts_ref" => "bad", "operations" => [] }],
                      "lts" => [{ "id" => "bad", "initial" => "s0", "transitions" => [{}] }] }
    expect { described_class::Validator.validate!(malformed_lts, verify_checksum: false) }
      .to raise_error(Bparity::InvalidBundleError, /each LTS transition needs/)
  end

  it "rejects malformed contracts" do
    malformed_contract = {
      "spec_bundle_version" => 2,
      "subjects" => [{ "name" => "Value", "operations" => [{ "name" => "#call", "examples" => [],
                                                             "invariants" => [{}] }] }]
    }
    expect { described_class::Validator.validate!(malformed_contract, verify_checksum: false) }
      .to raise_error(Bparity::InvalidBundleError, /entry needs a non-empty ID and expression/)
  end
end
