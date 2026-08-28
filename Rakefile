# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"
require "tmpdir"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

task default: %i[spec rubocop]

desc "Measure recording overhead against the pure-function fixture"
task :benchmark_recording do
  plain = [RbConfig.ruby, "-Ilib", "-r./fixtures/scenarios/01_pure_function/legacy/slugifier.rb",
           "-S", "rspec", "fixtures/scenarios/01_pure_function/spec/slugifier_spec.rb"]
  Dir.mktmpdir do |directory|
    recorded = [RbConfig.ruby, "-Ilib", "exe/bparity", "record", "--boundary",
                "fixtures/scenarios/01_pure_function/boundary.rb", "--out", File.join(directory, "corpus.jsonl"),
                "--coverage", File.join(directory, "coverage.json"), "--require",
                "fixtures/scenarios/01_pure_function/legacy/slugifier.rb"]
    median = lambda do |command|
      5.times.map do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        abort "Benchmark command failed: #{command.join(' ')}" unless system(*command, out: File::NULL, err: File::NULL)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end.sort[2]
    end
    baseline = median.call(plain)
    instrumented = median.call(recorded)
    overhead = ((instrumented / baseline) - 1) * 100
    puts format("Recording overhead: %<overhead>.1f%% (plain %<plain>.3fs, recorded %<recorded>.3fs)",
                overhead:, plain: baseline, recorded: instrumented)
    abort "Recording overhead exceeds 50%" if overhead > 50
  end
end
