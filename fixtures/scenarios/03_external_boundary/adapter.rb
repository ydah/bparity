# frozen_string_literal: true

Bparity.adapter do
  external "RetiredFormatter::Money" => "Replacement::Currency" do
    map_call(:render) { |call| call.merge("method" => "format") }
  end
  subject "Receipt" do
    construct { Replacement::ReceiptView.new }
    operation "#print" do
      invoke { |view, args, _kwargs| view.render(total: args.fetch(0)) }
    end
  end
end
