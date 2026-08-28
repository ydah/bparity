# frozen_string_literal: true

Bparity.adapter do
  subject "Identity" do
    construct { Replacement::Identity }
    operation "#label" do
      invoke { |identity, args, _kwargs| identity.display(value: args.fetch(0)) }
    end
  end
  waive "bc-000001", reason: "The replacement uses inclusive terminology",
                     approved_by: "migration-owner", approved_at: "2026-08-28"
end
