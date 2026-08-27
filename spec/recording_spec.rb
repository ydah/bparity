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
end
