# frozen_string_literal: true

Bparity.adapter do
  subject "PureToken" do
    construct { Replacement::PureTokenService }
    operation("#token") { invoke { |service, args, _kwargs| service.shift(*args) } }
  end
  subject "Turnstile" do
    construct { Replacement::Gate.new }
    state { |gate| { locked: gate.phase == :secured } }
    operation("#unlock") { invoke { |gate, _args, _kwargs| gate.release } }
    operation("#lock") { invoke { |gate, _args, _kwargs| gate.secure } }
    operation("#enter") { invoke { |gate, _args, _kwargs| gate.pass } }
  end
end
