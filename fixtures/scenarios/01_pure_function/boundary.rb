# frozen_string_literal: true

Bparity.boundary do
  observe "Legacy::Slugifier" do
    methods :call
  end

  external "DeadGem::Transliterator" do
    methods :transliterate
  end

  driver :rspec, files: "fixtures/scenarios/01_pure_function/spec/**/*_spec.rb"
  formal do
    pure_fragment "Legacy::Slugifier#call"
    bounded_scope size: 3, depth: 2
  end
end
