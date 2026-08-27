# frozen_string_literal: true

Bparity.adapter do
  external "DeadGem::Transliterator" => "Replacement::Transliterator"

  subject "Slugifier" do
    construct { Replacement::Slugs }
    operation "#call" do
      invoke { |subject, args, _kwargs| subject.generate(text: args.fetch(0)) }
      map_error { |error| { class: error.class.name, message: error.message, cause: error.cause&.class&.name } }
    end
  end
end
