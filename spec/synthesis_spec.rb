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
      expect(item).to include("description" => "Slugifier with spaces uses hyphens", "assertions" => ["eq"])
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
end
