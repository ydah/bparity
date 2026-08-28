# frozen_string_literal: true

Bparity.boundary do
  observe "Legacy::Identity" do
    methods :label
  end
  driver :rspec, files: "fixtures/scenarios/04_intentional_divergence/spec/**/*_spec.rb"
end
