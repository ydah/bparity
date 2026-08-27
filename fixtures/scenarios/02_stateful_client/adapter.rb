# frozen_string_literal: true

Bparity.adapter do
  subject "Client" do
    construct { Replacement::Session.new }
    state { |session| { open: session.phase == :ready } }

    operation("#connect") do
      invoke { |session, _args, _kwargs| session.start; true }
    end
    operation("#fetch") do
      invoke { |session, _args, _kwargs| session.query }
      map_error { |error| { class: "Legacy::NotConnectedError", message: error.message } }
    end
    operation("#close") do
      invoke { |session, _args, _kwargs| session.shutdown; nil }
    end
  end
end
