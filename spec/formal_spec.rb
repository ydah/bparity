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

    it "enumerates bounded arrays and hashes from observed element types" do
      arrays = described_class.new(size: 2, depth: 1, observed: [[true]]).values("Array")
      hashes = described_class.new(size: 1, depth: 1, observed: [{ true => false }]).values("Hash")

      expect(arrays).to contain_exactly([], [false], [true], [false, false], [false, true], [true, false],
                                        [true, true])
      expect(hashes).to contain_exactly({}, { false => false }, { false => true }, { true => false },
                                        { true => true })
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
                                     "counterexample" => include("input" => [0]))
    end

    it "is inconclusive rather than exhaustive when the case limit is reached" do
      result = described_class.new(old_callable: ->(value) { value }, new_callable: ->(value) { value },
                                   domains: [[1, 2, 3]], size: 1, depth: 1, assumptions: %i[h1], max_cases: 1).run
      expect(result.to_h).to include("verdict" => "inconclusive",
                                     "scope" => include("exhaustive" => false))
    end
  end
end
