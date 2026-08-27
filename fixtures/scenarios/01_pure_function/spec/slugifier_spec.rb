# frozen_string_literal: true

require "rspec"
require_relative "../legacy/slugifier"

RSpec.describe Legacy::Slugifier do
  subject(:slugifier) { described_class.new }

  it "converts spaces to hyphens" do
    expect(slugifier.call("Hello World")).to eq("hello-world")
  end

  it "removes punctuation at both ends" do
    expect(slugifier.call("  Hi!  ")).to eq("hi")
  end

  it "rejects blank input" do
    expect { slugifier.call("") }.to raise_error(ArgumentError, "blank")
  end
end
