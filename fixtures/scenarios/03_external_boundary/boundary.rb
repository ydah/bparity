# frozen_string_literal: true

Bparity.boundary do
  observe "Legacy::Receipt" do
    methods :print
  end
  external "RetiredFormatter::Money" do
    methods :format
  end
  driver :rspec, files: "fixtures/scenarios/03_external_boundary/spec/**/*_spec.rb"
end
