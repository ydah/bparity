# frozen_string_literal: true

Bparity.boundary do
  observe "Legacy::PureToken" do
    methods :token
  end
  observe "Legacy::Turnstile" do
    methods :unlock, :lock, :enter
    state { |turnstile| { locked: turnstile.locked } }
  end
  driver :rspec, files: "fixtures/scenarios/05_formal_negative/spec/**/*_spec.rb"
  formal do
    pure_fragment "Legacy::PureToken#token"
    lts_learning :active
  end
end
