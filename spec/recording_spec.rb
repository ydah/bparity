# frozen_string_literal: true

require "tmpdir"

RSpec.describe Bparity::Recording do
  let(:legacy_external) do
    Class.new do
      def send(value) = value.upcase
    end
  end
  let(:legacy_subject) do
    external = legacy_external
    Class.new do
      attr_reader :calls

      define_method(:initialize) do
        @external = external.new
        @calls = 0
      end

      def convert(value)
        @calls += 1
        yielded = yield(value) if block_given?
        @external.send(yielded || value)
      end
    end
  end

  before do
    stub_const("LegacyExternal", legacy_external)
    stub_const("LegacySubject", legacy_subject)
  end

  it "serializes supported Ruby values losslessly" do
    value = { status: :ok, values: [1, nil, Time.utc(2026, 8, 28)] }
    expect(described_class::Serializer.load(described_class::Serializer.dump(value))).to eq(value)
  end

  it "degrades cyclic values instead of overflowing the stack" do
    value = []
    value << value

    expect(described_class::Serializer.dump(value)).to eq([
                                                            { "$unserializable" => "Array",
                                                              "$reason" => "cyclic reference" }
                                                          ])
  end

  it "records arguments, yields, state, external calls, and outcomes as JSONL" do
    Dir.mktmpdir do |dir|
      boundary = Bparity.boundary do
        observe "LegacySubject" do
          methods :convert
          state { |subject| { calls: subject.calls } }
        end
        external "LegacyExternal" do
          methods :send
        end
      end
      writer = Bparity::Corpus::Writer.new(File.join(dir, "corpus.jsonl"))
      described_class::Recorder.new(boundary:, writer:).install!

      expect(LegacySubject.new.convert("hello") { |value| "#{value}!" }).to eq("HELLO!")
      writer.close

      record = Bparity::Corpus::Reader.new(writer.path).first
      expect(record).to include("operation" => "#convert",
                                "pre_state" => { "$hash" => [[{ "$symbol" => "calls" }, 0]] })
      expect(record["post_state"]).to eq("$hash" => [[{ "$symbol" => "calls" }, 1]])
      expect(record["yields"]).to eq([["hello"]])
      expect(record.dig("external_calls", 0, "method")).to eq("send")
      expect(record.dig("outcome", "value")).to eq("HELLO!")
    end
  end

  it "replaces an old corpus instead of appending duplicate identifiers" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "corpus.jsonl")
      writer = Bparity::Corpus::Writer.new(path)
      writer.write("id" => "old")
      writer.close
      writer = Bparity::Corpus::Writer.new(path)
      writer.write("id" => "new")
      writer.close

      expect(Bparity::Corpus::Reader.new(path).map { |record| record["id"] }).to eq(["new"])
    end
  end

  it "turns zero-count coverage branches into specification gaps" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "coverage.json")
      File.write(path, JSON.generate("files" => [{ "path" => "legacy.rb", "branches" => [
                                       { "type" => "then", "start_line" => 8, "end_line" => 9, "count" => 0 },
                                       { "type" => "else", "start_line" => 10, "end_line" => 11, "count" => 1 }
                                     ] }]))

      gaps = [{ "kind" => "uncovered_branch", "location" => "legacy.rb:8" }]
      expect(described_class::CoverageTracker.gaps(path)).to eq(gaps)
      expect(described_class::CoverageTracker.gaps(path, source_paths: ["replacement.rb"])).to be_empty
    end
  end

  it "normalizes configured time, random identifiers, and floats" do
    canonicalizer = described_class::Canonicalizer.new(
      freeze_time: "2020-01-01T00:00:00Z", uuid_placeholder: true, float_tolerance: 0.1
    )
    uuid = "550e8400-e29b-41d4-a716-446655440000"

    expected = [{ "$time" => "2020-01-01T00:00:00Z" }, "<ID:0>", 1.0]
    expect(canonicalizer.call([{ "$time" => "2026-01-01T00:00:00Z" }, uuid, 1.04])).to eq(expected)
  end

  it "freezes Time.now and Date.today only inside the recording context" do
    described_class::Determinism.apply(freeze_time: "2020-01-01T00:00:00Z")
    expect(Time.now).to eq(Time.utc(2020, 1, 1))
    expect(Date.today).to eq(Date.new(2020, 1, 1))
  ensure
    described_class::Determinism.clear
  end
end
