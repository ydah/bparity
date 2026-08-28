# frozen_string_literal: true

require "rspec"
require_relative "../legacy/receipt"

RSpec.describe Legacy::Receipt do
  it "renders money through the retired formatter" do
    expect(described_class.new.print(1_200)).to eq("Total: $12")
  end
end
