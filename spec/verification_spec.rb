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
end
