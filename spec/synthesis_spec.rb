# frozen_string_literal: true

require "tmpdir"

RSpec.describe Bparity::Synthesis do
  it "extracts nested RSpec descriptions and assertions with Prism" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "legacy_spec.rb")
      File.write(path, <<~RUBY)
        RSpec.describe "Slugifier" do
          context "with spaces" do
            it "uses hyphens" do
              expect(subject.call("a b")).to eq("a-b")
            end
          end
        end
      RUBY

      item = described_class::StaticExtractor.new.extract_tests([path]).first
      expect(item).to include("description" => "Slugifier with spaces uses hyphens", "assertions" => ["eq"],
                              "operation" => "#call", "arguments" => ["a b"],
                              "expected_outcome" => { "kind" => "return", "value" => "a-b" })
    end
  end

  it "extracts executable Minitest assertions" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "legacy_test.rb")
      File.write(path, <<~RUBY)
        class SlugifierTest < Minitest::Test
          def test_normalizes_a_title
            assert_equal "hello-world", Legacy::Slugifier.new.call("Hello World")
          end
        end
      RUBY

      item = described_class::StaticExtractor.new.extract_tests([path]).first
      expect(item).to include("subject" => "Legacy::Slugifier", "operation" => "#call",
                              "arguments" => ["Hello World"],
                              "expected_outcome" => { "kind" => "return", "value" => "hello-world" })
    end
  end

  it "merges matching static and recorded evidence as provenance A" do
    records = [{
      "id" => "bc-1", "subject" => "Legacy::Slugifier", "operation" => "#call",
      "provenance" => { "description" => "Slugifier works", "location" => "spec/x_spec.rb:2" },
      "args" => ["A"], "kwargs" => { "$hash" => [] }, "outcome" => { "kind" => "return", "value" => "a" }
    }]
    static = [{ "subject" => "Slugifier", "operation" => "#call",
                "description" => "Slugifier works", "assertions" => ["eq"], "arguments" => ["A"],
                "expected_outcome" => { "kind" => "return", "value" => "a" } }]

    bundle = described_class::Synthesizer.new(records:, static_examples: static).call
    example = bundle.dig("subjects", 0, "operations", 0, "examples", 0)
    expect(example).to include("provenance_level" => "A", "formal_level" => "F0")
  end

  it "does not promote unrelated static evidence with the same description" do
    records = [{ "id" => "bc-1", "subject" => "Legacy::Slugifier", "operation" => "#call",
                 "provenance" => { "description" => "works" },
                 "outcome" => { "kind" => "return", "value" => "ok" } }]
    static = [{ "subject" => "Slugifier", "operation" => "#other", "description" => "works",
                "assertions" => ["eq"], "arguments" => [],
                "expected_outcome" => { "kind" => "return", "value" => "ok" } }]

    example = described_class::Synthesizer.new(records:, static_examples: static).call
                                          .dig("subjects", 0, "operations", 0, "examples", 0)
    expect(example["provenance_level"]).to eq("B")
  end

  it "does not promote static evidence for another input or namespace" do
    records = [{ "id" => "bc-1", "subject" => "Legacy::Slugifier", "operation" => "#call", "args" => ["A"],
                 "provenance" => { "description" => "works" },
                 "outcome" => { "kind" => "return", "value" => "ok" } }]
    static = [{ "subject" => "Other::Slugifier", "operation" => "#call", "description" => "works",
                "assertions" => ["eq"], "arguments" => ["B"],
                "expected_outcome" => { "kind" => "return", "value" => "ok" } }]

    example = described_class::Synthesizer.new(records:, static_examples: static).call
                                          .dig("subjects", 0, "operations", 0, "examples", 0)
    expect(example["provenance_level"]).to eq("B")
  end

  it "does not promote a static assertion that contradicts the recording" do
    records = [{ "id" => "bc-1", "subject" => "Legacy::Slugifier", "operation" => "#call",
                 "provenance" => { "description" => "works" },
                 "outcome" => { "kind" => "return", "value" => "actual" } }]
    static = [{ "subject" => "Slugifier", "operation" => "#call", "description" => "works", "arguments" => [],
                "expected_outcome" => { "kind" => "return", "value" => "different" } }]

    example = described_class::Synthesizer.new(records:, static_examples: static).call
                                          .dig("subjects", 0, "operations", 0, "examples", 0)
    expect(example["provenance_level"]).to eq("B")
  end

  it "preserves canonicalization settings in the Specification Bundle" do
    records = [{ "id" => "bc-1", "subject" => "Clock", "operation" => "#now",
                 "canonicalization" => { "freeze_time" => "2020-01-01T00:00:00Z", "random_seed" => 42 },
                 "outcome" => { "kind" => "return", "value" => 1 } }]

    bundle = described_class::Synthesizer.new(records:).call
    expect(bundle["canonicalization"]).to eq("freeze_time" => "2020-01-01T00:00:00Z", "random_seed" => 42)
  end

  it "declares the complete H1 through H7 assumption catalog" do
    bundle = described_class::Synthesizer.new(records: [{ "subject" => "Value", "operation" => "#call",
                                                          "outcome" => { "kind" => "return", "value" => 1 } }]).call
    expect(bundle.fetch("verification_assumptions").map { |item| item.fetch("id") }).to eq(%w[H1 H2 H3 H4 H5 H6 H7])
  end

  it "keeps observed parameter values JSON-safe in a persisted bundle" do
    records = [{ "id" => "bc-1", "subject" => "Legacy::Value", "operation" => "#call",
                 "args" => [{ "$symbol" => "ok" }], "outcome" => { "kind" => "return", "value" => true } }]

    Dir.mktmpdir do |dir|
      path = File.join(dir, "spec.yml")
      bundle = described_class::Synthesizer.new(records:).call
      Bparity::SpecBundle::Writer.write(path, bundle)
      loaded = Bparity::SpecBundle::Loader.load(path)
      expect(loaded.dig("subjects", 0, "operations", 0, "params", 0)).to include(
        "types" => ["Symbol"], "observed_values" => [{ "$symbol" => "ok" }]
      )
    end
  end

  it "turns legacy raise guards into operation preconditions instead of gaps" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "guarded.rb")
      File.write(path, <<~RUBY)
        module Legacy
          class Guarded
            def call(value)
              raise ArgumentError, "missing" if value.nil?
              value
            end
          end
        end
      RUBY
      facts = described_class::StaticExtractor.new.extract_source([path])
      records = [{ "id" => "bc-1", "subject" => "Legacy::Guarded", "operation" => "#call",
                   "args" => ["ok"], "outcome" => { "kind" => "return", "value" => "ok" } }]
      bundle = described_class::Synthesizer.new(records:, source_facts: facts).call

      expect(bundle.dig("subjects", 0, "operations", 0, "preconditions", 0)).to include(
        "expr" => "!(args[0].nil?)", "formal_level" => "F1"
      )
      expect(bundle["gaps"]).to be_empty
    end
  end

  it "mines supported nontrivial invariants from repeated observations" do
    records = %w[one two].map do |value|
      { "outcome" => { "kind" => "return", "value" => value } }
    end

    expressions = described_class::InvariantMiner.new.mine(records).map { |item| item["expr"] }
    expect(expressions).to include("return != nil", "return.is_a?(String)", "return.match?(/\\A[a-z0-9-]*\\z/)")
  end

  it "prioritizes diverse behavior when limiting bundle examples" do
    common = 51.times.map do |index|
      { "id" => "bc-#{index}", "subject" => "Legacy::Value", "operation" => "#call", "args" => [1],
        "outcome" => { "kind" => "return", "value" => 1 } }
    end
    distinct = { "id" => "bc-distinct", "subject" => "Legacy::Value", "operation" => "#call", "args" => [2],
                 "outcome" => { "kind" => "return", "value" => 2 } }

    examples = described_class::Synthesizer.new(records: common + [distinct]).call
                                           .dig("subjects", 0, "operations", 0, "examples")
    expect(examples.map { |example| example["id"] }).to include("bc-distinct")
    expect(examples.length).to eq(50)
  end

  it "detects additive and monotonic metamorphic relations" do
    relations = described_class::MetamorphicDetector.new.detect(->(value) { value * 2 }, [-1, 0, 1])
    expect(relations).to include("additive", "monotonic")
  end

  it "detects permutation invariance even when idempotence is not type-compatible" do
    relations = described_class::MetamorphicDetector.new.detect(lambda(&:sum), [[1, 2], [3, 2]])
    expect(relations).to include("permutation_invariant")
    expect(described_class::MetamorphicDetector.new.detect(->(value) { value }, [])).to be_empty
  end
end
