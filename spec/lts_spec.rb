# frozen_string_literal: true

RSpec.describe Bparity::Formal::LTS do
  let(:old_lts) do
    described_class.new(initial: "closed", transitions: [
                          { "from" => "closed", "input" => "#open", "output" => "ok", "to" => "open" },
                          { "from" => "open", "input" => "#close", "output" => "ok", "to" => "closed" },
                          { "from" => "closed", "input" => "#close", "output" => "error", "to" => "closed" },
                          { "from" => "open", "input" => "#open", "output" => "ok", "to" => "open" }
                        ])
  end

  it "learns a finite model by actively exploring projected states" do
    client = Class.new do
      attr_reader :open

      def initialize = @open = false
      def open! = @open = true
      def close! = @open = false
    end
    learned = Bparity::Formal::ActiveLearner.new(factory: -> { client.new }, state_projection: lambda(&:open),
                                                 operations: { "#open" => lambda(&:open!),
                                                               "#close" => lambda(&:close!) }).learn
    expect(learned).to have_attributes(complete: true, query_count: 4)
    expect(learned.lts).to have_attributes(states: %w[s0 s1], alphabet: %w[#close #open])
  end

  it "finds no difference when state names differ but traces match" do
    renamed = described_class.new(initial: "q0", transitions: old_lts.transitions.map do |transition|
      { "from" => transition.from == "closed" ? "q0" : "q1", "input" => transition.input,
        "output" => transition.output, "to" => transition.to == "closed" ? "q0" : "q1" }
    end)

    result = Bparity::Formal::LtsEquivalence.new.compare(old_lts, renamed)
    expect(result.to_h).to include("verdict" => "no_difference_found",
                                   "details" => include("caveat" => /learned models/))
  end

  it "returns the shortest distinguishing sequence" do
    broken = described_class.new(initial: "closed", transitions: old_lts.transitions.map do |transition|
      data = transition.to_h
      data["output"] = "wrong" if transition.from == "open" && transition.input == "#close"
      data
    end)

    result = Bparity::Formal::LtsEquivalence.new.compare(old_lts, broken)
    expect(result.to_h).to include("verdict" => "difference_found",
                                   "counterexample" => { "sequence" => %w[#open #close] })
  end

  it "exports valid Aldebaran structure and generates W-method sequences" do
    exported = Bparity::Formal::AldebaranExporter.call(old_lts)
    sequences = Bparity::Formal::WMethod.new(old_lts).sequences

    expect(exported).to start_with("des (0,4,2)\n")
    expect(sequences).to include(%w[#open #close])
  end

  it "turns a distinguishing sequence into a runnable RSpec regression" do
    source = Bparity::Formal::CounterexampleRSpec.call(lts: old_lts, sequence: %w[#open #close],
                                                       subject_name: "Client")
    expect(Prism.parse(source)).to be_success
    expect(source).to include("#open", "#close", "BPARITY_ADAPTER")
  end
end
