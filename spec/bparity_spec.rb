# frozen_string_literal: true

RSpec.describe Bparity do
  after { described_class.reset! }

  it "exposes a version and the documented compatibility name" do
    expect(Bparity::VERSION).not_to be_nil
    expect(BehaviorParity).to equal(described_class)
  end

  it "builds observation boundaries" do
    definition = described_class.boundary do
      observe "String" do
        methods :upcase
        exclude :to_s
      end
      canonicalize { random_seed 42 }
      driver :rspec, files: "spec/**/*_spec.rb"
    end

    expect(definition.subjects.fetch("String").method_names).to eq([:upcase])
    expect(definition.canonicalization).to eq(random_seed: 42)
  end

  it "uses actionable English configuration errors" do
    expect { described_class.constantize("Missing::Target") }
      .to raise_error(Bparity::ConfigurationError, /Cannot find Missing::Target.*Require/)
  end
end
