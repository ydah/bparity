# frozen_string_literal: true

Bparity.boundary do
  observe "Legacy::Client" do
    methods :connect, :fetch, :close
    state { |client| { open: client.status == :open } }
  end
  driver :rspec, files: "fixtures/scenarios/02_stateful_client/spec/**/*_spec.rb"
  formal { lts_learning :active }
end
