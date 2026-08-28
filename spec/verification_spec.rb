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
    expect { described_class::Comparator.new(mode: :contract).compare(expected, "anything") }
      .to raise_error(Bparity::ConfigurationError, /requires operation contracts/)
  end

  it "distinguishes missing array entries from nil and mixed hash key types" do
    expect(described_class::Differ.call([nil], [])).to eq([
                                                            { "path" => "$[0]", "expected" => nil,
                                                              "actual" => "<missing>" }
                                                          ])
    expect { described_class::Differ.call({ "a" => 1 }, { a: 1 }) }.not_to raise_error
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

  it "checks executable invariants in contract mode" do
    contract_bundle = Marshal.load(Marshal.dump(bundle))
    operation = contract_bundle.dig("subjects", 0, "operations", 0)
    operation["invariants"] = [{ "id" => "inv-1", "expr" => 'return == "hello-world"' }]
    adapter = Bparity.adapter do
      subject "Slugifier" do
        construct { ReplacementSlug.new }
        operation("#call") { invoke { |_subject, _args, _kwargs| "broken" } }
      end
    end

    result = described_class::Runner.new(bundle: contract_bundle, adapter:, mode: :contract).run.first
    expect(result.status).to eq(:fail)
    expect(result.differences.first["path"]).to eq("$.contracts.inv-1")
  end

  it "fails closed when a contract precondition cannot be compiled" do
    contract_bundle = Marshal.load(Marshal.dump(bundle))
    operation = contract_bundle.dig("subjects", 0, "operations", 0)
    operation["preconditions"] = [{ "id" => "pre-1", "expr" => "result.system('unsafe')" }]
    operation["invariants"] = [{ "id" => "inv-1", "expr" => "return != nil" }]
    adapter = Bparity.adapter do
      subject "Slugifier" do
        construct { ReplacementSlug.new }
        operation("#call") { invoke { |subject, args, _kwargs| subject.generate(text: args.fetch(0)) } }
      end
    end

    result = described_class::Runner.new(bundle: contract_bundle, adapter:, mode: :contract).run.first
    expect(result).to have_attributes(status: :fail, differences: [include("path" => "$.contracts.pre-1")])
  end

  it "does not duplicate external calls across repeated verification runs" do
    external = Class.new { def deliver(value) = value.upcase }
    service = Class.new { def call(value) = ReplacementExternal.new.deliver(value) }
    stub_const("ReplacementExternal", external)
    stub_const("ReplacementWithExternal", service)
    external_bundle = {
      "subjects" => [{ "name" => "Service", "operations" => [{ "name" => "#call", "examples" => [{
        "id" => "ex-ext", "given" => { "args" => ["hi"], "kwargs" => {} }, "provenance" => {},
        "expect" => { "outcome" => { "kind" => "return", "value" => "HI" }, "post_state" => nil,
                      "yields" => [], "mutated_args" => [], "external_calls" => [{
                        "target" => "LegacyExternal", "method" => "deliver", "args" => ["hi"],
                        "kwargs" => { "$hash" => [] },
                        "outcome" => { "kind" => "return", "value" => "HI" }
                      }] }
      }] }] }]
    }
    adapter = Bparity.adapter do
      external "LegacyExternal" => "ReplacementExternal"
      subject "Service" do
        construct { ReplacementWithExternal.new }
        operation("#call")
      end
    end

    statuses = 2.times.map { described_class::Runner.new(bundle: external_bundle, adapter:).run.first.status }
    expect(statuses).to eq(%i[pass pass])
  end

  it "preserves external calls when the replacement raises" do
    external = Class.new { def deliver = raise("offline") }
    service = Class.new { def call = ReplacementFailingExternal.new.deliver }
    stub_const("ReplacementFailingExternal", external)
    stub_const("ReplacementWithFailingExternal", service)
    external_bundle = {
      "subjects" => [{ "name" => "Service", "operations" => [{ "name" => "#call", "examples" => [{
        "id" => "ex-ext-error", "given" => { "args" => [], "kwargs" => {} }, "provenance" => {},
        "expect" => { "outcome" => { "kind" => "raise", "class" => "RuntimeError", "message" => "offline",
                                     "cause" => nil },
                      "post_state" => nil, "yields" => [], "mutated_args" => [], "external_calls" => [{
                        "target" => "LegacyExternal", "method" => "deliver", "args" => [],
                        "kwargs" => { "$hash" => [] },
                        "outcome" => { "kind" => "raise", "class" => "RuntimeError", "message" => "offline" }
                      }] }
      }] }] }]
    }
    adapter = Bparity.adapter do
      external "LegacyExternal" => "ReplacementFailingExternal"
      subject "Service" do
        construct { ReplacementWithFailingExternal.new }
        operation("#call")
      end
    end

    expect(described_class::Runner.new(bundle: external_bundle, adapter:).run.first.status).to eq(:pass)
  end

  it "compares destructive argument changes" do
    mutator = Class.new { def call(value) = value << "changed" }
    stub_const("ReplacementMutator", mutator)
    mutation_bundle = Marshal.load(Marshal.dump(bundle))
    example = mutation_bundle.dig("subjects", 0, "operations", 0, "examples", 0)
    example["given"]["args"] = [["original"]]
    example["expect"]["outcome"]["value"] = %w[original changed]
    example["expect"]["post_state"] = nil
    example["expect"]["mutated_args"] = [0]
    adapter = Bparity.adapter do
      subject "Slugifier" do
        construct { ReplacementMutator.new }
        operation("#call")
      end
    end

    expect(described_class::Runner.new(bundle: mutation_bundle, adapter:).run.first.status).to eq(:pass)
  end

  it "rejects invalid and unknown waivers" do
    expect do
      Bparity.adapter { waive "ex-1", reason: "", approved_by: "owner", approved_at: "2026-08-28" }
    end.to raise_error(Bparity::ConfigurationError, /missing reason/)
    expect do
      Bparity.adapter { waive "ex-1", reason: "approved", approved_by: "owner", approved_at: "tomorrow" }
    end.to raise_error(Bparity::ConfigurationError, /invalid approval date/)

    adapter = Bparity.adapter do
      waive "not-in-bundle", reason: "approved", approved_by: "owner", approved_at: "2026-08-28"
      subject "Slugifier" do
        construct { ReplacementSlug.new }
        operation("#call")
      end
    end
    expect { described_class::Runner.new(bundle:, adapter:).run }
      .to raise_error(Bparity::ConfigurationError, /not found in the Spec Bundle/)
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
