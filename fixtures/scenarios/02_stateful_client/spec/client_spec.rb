# frozen_string_literal: true

require "rspec"
require_relative "../legacy/client"

RSpec.describe Legacy::Client do
  subject(:client) { described_class.new }

  it "fetches after connecting" do
    expect(client.connect).to be(true)
    expect(client.fetch).to eq(:data)
  end

  it "rejects fetch while closed" do
    expect { client.fetch }.to raise_error(Legacy::NotConnectedError)
  end

  it "closes an open client" do
    client.connect
    expect(client.close).to be_nil
  end

  it "allows repeated connect" do
    client.connect
    expect(client.connect).to be(true)
  end

  it "allows close while already closed" do
    expect(client.close).to be_nil
  end
end
