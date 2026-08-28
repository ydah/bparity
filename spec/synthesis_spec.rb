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
    static = [{ "description" => "Slugifier works", "assertions" => ["eq"] }]

    bundle = described_class::Synthesizer.new(records:, static_examples: static).call
    example = bundle.dig("subjects", 0, "operations", 0, "examples", 0)
    expect(example).to include("provenance_level" => "A", "formal_level" => "F0")
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
end
