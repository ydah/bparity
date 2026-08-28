# frozen_string_literal: true

require "tmpdir"

RSpec.describe Bparity::Formal do
  describe Bparity::Formal::Result do
    let(:scope) { Bparity::Formal::Scope.new(size: 2, depth: 1, cases: 3, exhaustive: true) }

    it "forbids an equivalent verdict and requires scope and assumptions" do
      expect do
        described_class.new(level: :f2, verdict: :equivalent, scope:, assumptions: [], out_of_scope: [])
      end.to raise_error(Bparity::ConfigurationError, /Invalid formal verdict/)
    end
  end

  describe Bparity::Formal::ContractCompiler do
    it "evaluates allowed first-order predicates without eval" do
      predicate = described_class.new.compile("return.size == args[0].size")
      expect(predicate.call(result: "abc", args: ["xyz"])).to be(true)
    end

    it "rejects arbitrary method calls" do
      expect { described_class.new.compile("return.system('echo unsafe')") }
        .to raise_error(Bparity::ConfigurationError, /not allowed/)
    end
  end

  describe Bparity::Formal::Assumptions do
    it "detects a target class changing during verification" do
      target = Class.new { def value = 1 }
      _value, violations = described_class::WorldFreeze.new([target]).check do
        target.class_eval { def value = 2 }
      end
      expect(violations).to include(/H1/)
    end

    it "tracks separate anonymous classes without fingerprint collisions" do
      first = Class.new { def value = 1 }
      second = Class.new { def value = 1 }
      _value, violations = described_class::WorldFreeze.new([first, second]).check do
        first.class_eval { def value = 2 }
      end
      expect(violations).to include(/H1/)
    end

    it "detects a method that is changed and restored during verification" do
      target = Class.new { def value = 1 }
      original = target.instance_method(:value)
      _value, violations = described_class::WorldFreeze.new([target]).check do
        target.class_eval { def value = 2 }
        target.define_method(:value, original)
      end
      expect(violations).to include(/H1/)
    end

    it "detects a singleton method that is changed and restored during verification" do
      target = Class.new { def self.value = 1 }
      original = target.method(:value)
      _value, violations = described_class::WorldFreeze.new([target.singleton_class]).check do
        target.define_singleton_method(:value) { 2 }
        target.define_singleton_method(:value, original)
      end
      expect(violations).to include(/H1/)
    end

    it "detects eval and dynamic send with Prism" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "dynamic.rb")
        File.write(path, "eval(code)\nobject.send(name)\n")
        violations = described_class::DynamicCodeDetector.new.scan([path])
        expect(violations.map { |item| item["reason"] }).to contain_exactly("dynamic call eval", "dynamic call send")
      end
    end
  end

  describe Bparity::Formal::ValueEnumerator do
    it "enumerates every string up to the requested size" do
      values = described_class.new(size: 2, depth: 1, alphabet: %w[a b]).values("String")
      expect(values).to contain_exactly("", "a", "b", "aa", "ab", "ba", "bb")
    end

    it "bounds domain construction and marks the result as truncated" do
      values = described_class.new(size: 8, depth: 1, alphabet: %w[a b c], limit: 10).values("String")
      expect(values).to have_attributes(length: 10, truncated: true)
    end

    it "enumerates bounded arrays and hashes from observed element types" do
      arrays = described_class.new(size: 2, depth: 1, observed: [[true]]).values("Array")
      hashes = described_class.new(size: 1, depth: 1, observed: [{ true => false }]).values("Hash")

      expect(arrays).to contain_exactly([], [false], [true], [false, false], [false, true], [true, false],
                                        [true, true])
      expect(hashes).to contain_exactly({}, { false => false }, { false => true }, { true => false },
                                        { true => true })
    end

    it "enumerates user structures while removing isomorphic candidates" do
      node_class = Class.new { attr_accessor :next }
      stub_const("KoratNode", node_class)
      first = KoratNode.new
      second = KoratNode.new
      enumerator = Bparity::Formal::KoratEnumerator.new(
        klass: KoratNode, fields: [:@next], domains: { :@next => [nil, first, second] }
      )

      expect(enumerator.values.length).to eq(2)
    end
  end

  describe Bparity::Formal::InputGenerator do
    it "adds unseen large and invalidly encoded boundary values" do
      integers = described_class.new(size: 1, depth: 1).values("Integer")
      strings = described_class.new(size: 1, depth: 1).values("String")

      expect(integers).to include(2**62, -(2**62))
      expect(strings).to include(" ")
      expect(strings).to include(satisfy { |value| value.is_a?(String) && !value.valid_encoding? })
    end
  end

  describe Bparity::Formal::ExhaustiveRunner do
    it "reports the bounded universal scope when all cases match" do
      result = described_class.new(old_callable: ->(value) { value * 2 }, new_callable: ->(value) { value + value },
                                   domains: [[-1, 0, 1]], size: 1, depth: 1, assumptions: %i[h1 h3]).run
      expect(result.to_h).to include("verdict" => "no_difference_found",
                                     "scope" => include("cases" => 3, "exhaustive" => true))
    end

    it "returns a concrete counterexample for different behavior" do
      result = described_class.new(old_callable: ->(value) { value * 2 }, new_callable: ->(value) { value + 1 },
                                   domains: [[0, 1]], size: 1, depth: 1, assumptions: %i[h1]).run
      expect(result.to_h).to include("verdict" => "difference_found",
                                     "counterexample" => include("input" => [0]),
                                     "scope" => include("exhaustive" => false),
                                     "details" => include("domains" => [include("count" => 2,
                                                                                "sample" => [0, 1])]))
    end

    it "is inconclusive rather than exhaustive when the case limit is reached" do
      result = described_class.new(old_callable: ->(value) { value }, new_callable: ->(value) { value },
                                   domains: [[1, 2, 3]], size: 1, depth: 1, assumptions: %i[h1], max_cases: 1).run
      expect(result.to_h).to include("verdict" => "inconclusive",
                                     "scope" => include("cases" => 1, "exhaustive" => false),
                                     "details" => include("fallback" => "pairwise", "fallback_cases" => 1))
    end

    it "never exceeds the total case limit during pairwise fallback" do
      calls = 0
      callable = lambda do |left, right|
        calls += 1
        [left, right]
      end
      result = described_class.new(old_callable: callable, new_callable: callable,
                                   domains: [[1, 2, 3], %w[a b c]], size: 3, depth: 1,
                                   assumptions: %i[h1], max_cases: 4).run

      expect(result.scope.cases).to eq(4)
      expect(calls).to eq(8)
    end

    it "checks declared contracts when the legacy implementation is unavailable" do
      result = described_class.new(new_callable: ->(value) { value }, domains: [[0, 1]], size: 1, depth: 1,
                                   assumptions: %i[h1],
                                   contracts: [{ "id" => "positive", "expr" => "return > 0" }]).run
      expect(result.to_h).to include("verdict" => "difference_found",
                                     "counterexample" => include("input" => [0], "violations" => [include(
                                       "id" => "positive"
                                     )]))
    end

    it "filters precondition violations without making a vacuous exhaustive claim" do
      result = described_class.new(new_callable: ->(value) { value }, domains: [[nil]], size: 1, depth: 1,
                                   assumptions: %i[h1], contracts: [{ "id" => "present", "expr" => "return != nil" }],
                                   preconditions: [{ "id" => "input", "expr" => "args[0] != nil" }]).run
      expect(result.to_h).to include("verdict" => "inconclusive", "scope" => include("cases" => 0),
                                     "details" => include("filtered_by_preconditions" => 1))
    end

    it "never reports an exhaustive result for a truncated input domain" do
      domain = Bparity::Formal::Domain.new([0, 1], truncated: true)
      result = described_class.new(old_callable: ->(value) { value }, new_callable: ->(value) { value },
                                   domains: [domain], size: 10, depth: 1, assumptions: %i[h1]).run
      expect(result.to_h).to include("verdict" => "inconclusive", "scope" => include("exhaustive" => false),
                                     "details" => include("domains" => [include("truncated" => true)]))
    end
  end

  describe Bparity::Formal::PropertyRunner do
    it "keeps a failing counterexample when smaller candidates pass" do
      invariant = [{ "id" => "short", "expr" => "return < 2" }]
      result = described_class.new(callable: lambda(&:length), invariants: invariant,
                                   inputs: [["long"]]).run

      expect(result["input"]).to eq(["long"])
    end

    it "reports replacement exceptions instead of silently skipping the input" do
      result = described_class.new(callable: ->(_value) { raise "broken" },
                                   invariants: [{ "id" => "present", "expr" => "return != nil" }],
                                   inputs: [[1]]).run
      expect(result).to include("input" => [0], "violations" => [include("id" => "execution", "error" => "broken")])
    end

    it "refuses a vacuous pass when generated inputs violate every precondition" do
      runner = described_class.new(callable: ->(value) { value },
                                   invariants: [{ "id" => "same", "expr" => "return == args[0]" }],
                                   preconditions: [{ "id" => "positive", "expr" => "args[0] > 0" }],
                                   inputs: [[0], [-1]])
      expect { runner.run }.to raise_error(Bparity::ConfigurationError, /no input satisfying the preconditions/)
    end

    it "does not shrink a counterexample outside its precondition" do
      runner = described_class.new(callable: ->(value) { value },
                                   invariants: [{ "id" => "small", "expr" => "return < 2" }],
                                   preconditions: [{ "id" => "positive", "expr" => "args[0] > 0" }],
                                   inputs: [[2]])
      expect(runner.run.fetch("input")).to eq([2])
    end
  end

  describe Bparity::Formal::DifferentialRunner do
    it "compares legacy and replacement observations in separate processes" do
      reader = "input = JSON.parse(STDIN.read); puts JSON.generate('value' => input[0] + OFFSET)"
      old_command = [RbConfig.ruby, "-rjson", "-e", "OFFSET = 1; #{reader}"]
      new_command = [RbConfig.ruby, "-rjson", "-e", "OFFSET = 2; #{reader}"]

      differences = described_class.new(old_command:, new_command:, inputs: [[1]]).run
      expect(differences).to contain_exactly(include("input" => [1],
                                                     "differences" => [include("path" => "$.value")]))
    end

    it "transports invalid UTF-8 inputs through JSON-safe bytes" do
      command = [RbConfig.ruby, "-rjson", "-e", "puts JSON.generate(JSON.parse(STDIN.read))"]
      invalid = "\xFF".b.force_encoding(Encoding::UTF_8)
      expect(described_class.new(old_command: command, new_command: command, inputs: [[invalid]]).run).to be_empty
    end
  end
end
