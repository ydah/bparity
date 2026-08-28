# frozen_string_literal: true

Bparity.adapter do
  subject "Identity" do
    construct { Replacement::Identity }
    operation "#label" do
      invoke { |identity, args, _kwargs| identity.display(value: args.fetch(0)) }
    end
  end
end
