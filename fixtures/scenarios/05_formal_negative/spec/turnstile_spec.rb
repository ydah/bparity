# frozen_string_literal: true

require "rspec"
require_relative "../legacy/turnstile"

RSpec.describe Legacy::Turnstile do
  it "exposes a pure fragment for F2 and F4 negative checks" do
    expect(Legacy::PureToken.new.token(1)).to eq(2)
  end

  it "covers every operation from locked and unlocked states" do
    turnstile = described_class.new
    expect(turnstile.lock).to eq(:ok)
    expect(turnstile.enter).to eq(:denied)
    expect(turnstile.unlock).to eq(:ok)
    expect(turnstile.unlock).to eq(:ok)
    expect(turnstile.lock).to eq(:ok)
    expect(turnstile.unlock).to eq(:ok)
    expect(turnstile.enter).to eq(:entered)
  end
end
