# frozen_string_literal: true

require "tmpdir"

RSpec.describe Bparity::Formal::Deductive do
  def with_sources
    Dir.mktmpdir do |dir|
      old_path = File.join(dir, "old.rb")
      new_path = File.join(dir, "new.rb")
      File.write(old_path, "class OldMath\n  def double(value) = value + value\nend\n")
      File.write(new_path, "class NewMath\n  def twice(number) = number * 2\nend\n")
      yield old_path, new_path
    end
  end

  it "translates compatible pure methods into a product program" do
    with_sources do |old_path, new_path|
      translator = described_class::RubyToSmt.new
      old_translation = translator.translate_file(old_path, :double, parameter_types: ["Integer"])
      new_translation = translator.translate_file(new_path, :twice, parameter_types: ["Integer"])
      script = described_class::ProductProgram.call(old_translation, new_translation)

      expect(script).to include("(declare-const arg0 Int)", "(assert (not (= (+ arg0 arg0) (* arg0 2))))")
    end
  end

  it "returns F4 only after translation validation and an unsat solver result" do
    with_sources do |old_path, new_path|
      translator = described_class::RubyToSmt.new
      old_translation = translator.translate_file(old_path, :double, parameter_types: ["Integer"])
      new_translation = translator.translate_file(new_path, :twice, parameter_types: ["Integer"])
      solver = Class.new do
        def available? = true
        def solve(_script) = { verdict: :unsat, output: "unsat" }
      end.new

      result = described_class::Runner.new(old_translation:, new_translation:,
                                           old_callable: ->(value) { value + value },
                                           new_callable: ->(value) { value * 2 },
                                           validation_inputs: [[-1], [0], [1]], solver:).run
      expect(result.to_h).to include("level" => "F4", "verdict" => "no_difference_found",
                                     "details" => include("reason" => "Z3 returned unsat"))
    end
  end

  it "invalidates a proof when an injected translation bug disagrees with Ruby" do
    translation = described_class::Translation.new(parameters: [%w[arg0 Int]],
                                                   term: described_class::Term.new("(+ arg0 1)", "Int") do |context|
                                                     context.fetch(0) + 1
                                                   end)
    solver = Class.new { def available? = true }.new
    result = described_class::Runner.new(old_translation: translation, new_translation: translation,
                                         old_callable: ->(value) { value }, new_callable: ->(value) { value },
                                         validation_inputs: [[0]], solver:).run
    expect(result.to_h).to include("verdict" => "inconclusive",
                                   "details" => include("reason" => "translation validation failed"))
  end

  it "reports a solver model for a nonequivalent pure fragment" do
    Dir.mktmpdir do |dir|
      old_path = File.join(dir, "old.rb")
      new_path = File.join(dir, "new.rb")
      File.write(old_path, "def token(value) = value + 1\n")
      File.write(new_path, "def shift(value) = value + 2\n")
      translator = described_class::RubyToSmt.new
      old_translation = translator.translate_file(old_path, :token, parameter_types: ["Integer"])
      new_translation = translator.translate_file(new_path, :shift, parameter_types: ["Integer"])
      solver = Class.new do
        def available? = true
        def solve(_script) = { verdict: :sat, output: "((arg0 0))" }
      end.new

      result = described_class::Runner.new(old_translation:, new_translation:,
                                           old_callable: ->(value) { value + 1 },
                                           new_callable: ->(value) { value + 2 },
                                           validation_inputs: [[-1], [0], [1]], solver:).run
      expect(result.to_h).to include("verdict" => "difference_found",
                                     "counterexample" => { "solver_model" => "((arg0 0))" })
    end
  end

  it "rejects dynamic Ruby from the verifiable fragment" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dynamic.rb")
      File.write(path, "def unsafe(code) = eval(code)\n")
      expect(described_class::FragmentChecker.new.check_file(path, :unsafe)).to include(/eval/)
    end
  end
end
