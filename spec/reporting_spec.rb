# frozen_string_literal: true

RSpec.describe Bparity::Reporting do
  let(:result) do
    Bparity::Verification::Result.new(id: "ex-1", status: :pass, description: "works", differences: [],
                                      provenance: {})
  end
  let(:bundle) do
    {
      "subjects" => [{ "operations" => [{ "examples" => [
        { "provenance_level" => "A", "formal_level" => "F2" }
      ], "invariants" => [] }] }],
      "gaps" => [{ "kind" => "uncovered_branch", "location" => "legacy.rb:4" }]
    }
  end

  it "reports the provenance matrix and five-point assessment" do
    reporter = described_class::Reporter.new([result], bundle:)
    summary = reporter.summary

    expect(summary.dig("assurance_matrix", "A", "F2")).to eq(1)
    expect(summary.dig("five_point_assessment", "residual_risks")).to eq(["Legacy gap: legacy.rb:4"])
    expect(reporter.markdown).to include("Five-point assessment", "Specification coverage")
    expect(reporter.html).to include("Provenance × formal assurance", "Five-point assessment")
  end
end
