# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "bparity/cli"

module FixtureAcceptance
  ROOT = File.expand_path("..", __dir__)
  SCENARIOS = {
    "01_pure_function" => ["legacy/slugifier.rb", "replacement/good.rb", "replacement/broken.rb"],
    "02_stateful_client" => ["legacy/client.rb", "replacement/good.rb", "replacement/broken.rb"],
    "03_external_boundary" => ["legacy/receipt.rb", "replacement/good.rb", "replacement/broken.rb"],
    "04_intentional_divergence" => ["legacy/identity.rb", "replacement/good.rb", "replacement/broken.rb"],
    "05_formal_negative" => ["legacy/turnstile.rb", "replacement/good.rb", "replacement/broken.rb"]
  }.freeze
end

RSpec.describe Bparity::CLI do
  let(:root) { FixtureAcceptance::ROOT }
  let(:scenarios) { FixtureAcceptance::SCENARIOS }

  def run_cli(*arguments)
    Open3.capture3(RbConfig.ruby, "-Ilib", "exe/bparity", *arguments, chdir: root)
  end

  def build_bundle(name, legacy, directory)
    base = "fixtures/scenarios/#{name}"
    corpus = File.join(directory, "corpus.jsonl")
    coverage = File.join(directory, "coverage.json")
    spec = File.join(directory, "spec.yml")
    _out, error, status = run_cli("record", "--boundary", "#{base}/boundary.rb", "--out", corpus,
                                  "--coverage", coverage, "--require", "#{base}/#{legacy}")
    raise error unless status.success?

    _out, error, status = run_cli("synthesize", "--corpus", corpus, "--out", spec, "--coverage", coverage,
                                  "--tests", "#{base}/spec/**/*_spec.rb", "--source", "#{base}/legacy/*.rb")
    raise error unless status.success?

    [base, spec]
  end

  FixtureAcceptance::SCENARIOS.each do |name, (legacy, good, broken)|
    it "accepts the good and detects the broken #{name} replacement" do
      Dir.mktmpdir do |directory|
        base, spec = build_bundle(name, legacy, directory)
        good_result = run_cli("verify", "--spec", spec, "--adapter", "#{base}/adapter.rb",
                              "--require", "#{base}/#{good}")
        broken_adapter = name == "04_intentional_divergence" ? "#{base}/adapter_unwaived.rb" : "#{base}/adapter.rb"
        broken_result = run_cli("verify", "--spec", spec, "--adapter", broken_adapter,
                                "--require", "#{base}/#{broken}")

        expect(good_result.last).to be_success
        expect(broken_result.last).not_to be_success
        expect(broken_result.first).to include("FAIL")
      end
    end
  end

  it "reports an explicit waiver" do
    Dir.mktmpdir do |directory|
      base, spec = build_bundle("04_intentional_divergence", scenarios.fetch("04_intentional_divergence").first,
                                directory)
      waived = run_cli("verify", "--spec", spec, "--adapter", "#{base}/adapter.rb",
                       "--require", "#{base}/replacement/broken.rb")
      expect(waived.last).to be_success
      expect(waived.first).to include("WAIVED", "approved by migration-owner on 2026-08-28")
    end
  end

  # rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations -- one shared bundle setup
  it "detects F2, F3, and F4 negative cases" do
    Dir.mktmpdir do |directory|
      base, spec = build_bundle("05_formal_negative", scenarios.fetch("05_formal_negative").first, directory)
      good = run_cli("prove", "--level", "f3", "--spec", spec, "--adapter", "#{base}/adapter.rb",
                     "--require", "#{base}/replacement/good.rb")
      broken = run_cli("prove", "--level", "f3", "--spec", spec, "--adapter", "#{base}/adapter.rb",
                       "--require", "#{base}/replacement/broken.rb")
      expect(good.first).to include('"verdict": "no_difference_found"')
      expect(broken.first).to include('"verdict": "difference_found"', '"sequence"')

      f2_good = run_cli("prove", "--level", "f2", "--scope", "size=2,depth=1", "--spec", spec,
                        "--subject", "PureToken", "--operation", "#token",
                        "--adapter", "#{base}/adapter.rb", "--require", "#{base}/legacy/turnstile.rb",
                        "--require", "#{base}/replacement/good.rb")
      f2_broken = run_cli("prove", "--level", "f2", "--scope", "size=2,depth=1", "--spec", spec,
                          "--subject", "PureToken", "--operation", "#token",
                          "--adapter", "#{base}/adapter.rb", "--require", "#{base}/legacy/turnstile.rb",
                          "--require", "#{base}/replacement/formal_broken.rb", "--counterexample-out",
                          File.join(directory, "f2_counterexample_spec.rb"))
      expect(f2_good.first).to include('"verdict": "no_difference_found"')
      expect(f2_broken.first).to include('"verdict": "difference_found"')
      expect(File.read(File.join(directory, "f2_counterexample_spec.rb"))).to include("F2 counterexample",
                                                                                      "expect(actual).to eq")

      f4_broken = run_cli("prove", "--level", "f4", "--validate-translation", "--types", "Integer",
                          "--subject", "PureToken", "--operation", "#token",
                          "--spec", spec, "--adapter", "#{base}/adapter.rb",
                          "--old-source", "#{base}/legacy/turnstile.rb", "--old-method", "token",
                          "--new-source", "#{base}/replacement/formal_broken.rb", "--new-method", "shift",
                          "--require", "#{base}/legacy/turnstile.rb",
                          "--require", "#{base}/replacement/formal_broken.rb", "--counterexample-out",
                          File.join(directory, "f4_counterexample_spec.rb"))
      if ENV["BPARITY_Z3"]
        expect(f4_broken.first).to include('"verdict": "difference_found"', '"input"')
        expect(File.read(File.join(directory, "f4_counterexample_spec.rb"))).to include("F4 counterexample")
        f4_good = run_cli("prove", "--level", "f4", "--validate-translation", "--types", "Integer",
                          "--subject", "PureToken", "--operation", "#token", "--spec", spec,
                          "--adapter", "#{base}/adapter.rb", "--old-source", "#{base}/legacy/turnstile.rb",
                          "--old-method", "token", "--new-source", "#{base}/replacement/good.rb",
                          "--new-method", "shift", "--require", "#{base}/legacy/turnstile.rb",
                          "--require", "#{base}/replacement/good.rb")
        expect(f4_good.first).to include('"verdict": "no_difference_found"',
                                         '"translation_validation_scope"')
      else
        expect(f4_broken.first).to include('"verdict": "inconclusive"')
      end
    end
  end

  it "records Minitest provenance" do
    Dir.mktmpdir do |directory|
      corpus = File.join(directory, "minitest.jsonl")
      result = run_cli("record", "--boundary", "fixtures/scenarios/01_pure_function/boundary.rb",
                       "--out", corpus, "--coverage", File.join(directory, "coverage.json"),
                       "--driver", "minitest", "--require",
                       "fixtures/scenarios/01_pure_function/legacy/slugifier.rb",
                       "fixtures/scenarios/01_pure_function/test/slugifier_test.rb")
      record = JSON.parse(File.readlines(corpus).first)

      expect(result.last).to be_success
      expect(record.dig("provenance", "example_id")).to include("SlugifierTest#test_normalizes_a_title")
    end
  end
end
