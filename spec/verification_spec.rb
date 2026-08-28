# frozen_string_literal: true

RSpec.describe Bparity::Verification do
  let(:replacement) do
    Class.new do
      attr_reader :count

      def initialize
        @count = 0
      end

      def generate(text:)
        @count += 1
        text.downcase.tr(" ", "-")
      end
    end
  end
  let(:bundle) do
    {
      "spec_bundle_version" => 2, "conformance_mode" => "refinement",
      "subjects" => [{ "name" => "Slugifier", "operations" => [{ "name" => "#call", "examples" => [{
        "id" => "ex-1", "provenance" => { "description" => "normalizes a title" },
        "given" => { "args" => ["Hello World"], "kwargs" => { "$hash" => [] } },
        "expect" => { "outcome" => { "kind" => "return", "value" => "hello-world" },
                      "post_state" => { "$hash" => [[{ "$symbol" => "count" }, 1]] }, "yields" => [],
                      "external_calls" => [], "mutated_args" => [] }
      }] }] }]
    }
  end

  before { stub_const("ReplacementSlug", replacement) }

  it "distinguishes strict, refinement, and contract modes" do
    expected = { "value" => 1 }
    actual = { "value" => 1, "metadata" => true }

    expect(described_class::Comparator.new(mode: :strict).compare(expected, actual)).not_to be_empty
    expect(described_class::Comparator.new(mode: :refinement).compare(expected, actual)).to be_empty
    expect(described_class::Comparator.new(mode: :contract).compare(expected, "anything")).to be_empty
  end

  it "replays a structurally different API through an adapter" do
    adapter = Bparity.adapter do
      subject "Slugifier" do
        construct { ReplacementSlug.new }
        state { |subject| { count: subject.count } }
        operation "#call" do
          invoke { |subject, args, _kwargs| subject.generate(text: args.fetch(0)) }
        end
      end
    end

    runner = described_class::Runner.new(bundle:, adapter:)
    expect(runner.run.map(&:status)).to eq([:pass])
    expect(runner).to be_success
  end

  it "reports a key-level difference for a broken implementation" do
    adapter = Bparity.adapter do
      subject "Slugifier" do
        construct { ReplacementSlug.new }
        state { |subject| { count: subject.count } }
        operation("#call") { invoke { |_subject, _args, _kwargs| "broken" } }
      end
    end

    result = described_class::Runner.new(bundle:, adapter:).run.first
    expect(result.status).to eq(:fail)
    expect(result.differences.map { |difference| difference["path"] }).to include("$.outcome.value")
  end

  it "preserves state across calls from the same legacy example" do
    stateful = Class.new do
      def initialize = @count = 0
      def increment = @count += 1
      def read = @count
    end
    stub_const("ReplacementCounter", stateful)
    expected = lambda do |id, operation, value|
      { "name" => operation, "examples" => [{
        "id" => id, "provenance" => { "example_id" => "counter example" },
        "given" => { "args" => [], "kwargs" => {} },
        "expect" => { "outcome" => { "kind" => "return", "value" => value }, "post_state" => nil,
                      "yields" => [], "external_calls" => [], "mutated_args" => [] }
      }] }
    end
    operations = [expected.call("ex-1", "#increment", 1), expected.call("ex-2", "#read", 1)]
    stateful_bundle = { "conformance_mode" => "refinement",
                        "subjects" => [{ "name" => "Counter", "operations" => operations }] }
    adapter = Bparity.adapter do
      subject "Counter" do
        construct { ReplacementCounter.new }
        operation("#increment")
        operation("#read")
      end
    end

    expect(described_class::Runner.new(bundle: stateful_bundle, adapter:).run.map(&:status)).to eq(%i[pass pass])
  end
end
