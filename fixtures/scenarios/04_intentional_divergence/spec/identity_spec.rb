# frozen_string_literal: true

require "rspec"
require_relative "../legacy/identity"

RSpec.describe Legacy::Identity do
  it "uses the legacy guest label" do
    expect(described_class.new.label(nil)).to eq("guest")
  end
end
