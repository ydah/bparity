# frozen_string_literal: true

require "bparity/cli"
require "stringio"

RSpec.describe Bparity::CLI do
  it "prints English errors with a next action" do
    output = StringIO.new
    status = described_class.start(["unknown"], out: StringIO.new, err: output)

    expect(status).to eq(2)
    expect(output.string).to include("unknown command", "Run `bparity help`")
    expect(output.string).not_to match(/[ぁ-んァ-ヶ一-龠]/)
  end
end
