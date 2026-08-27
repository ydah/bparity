# bparity

`bparity` captures the observable behavior of a legacy Ruby API, stores it as a portable specification bundle, and checks a structurally different replacement through a small adapter. The legacy dependency is not needed during verification.

## Installation

```bash
bundle add bparity
```

## Usage

Create `.bparity/boundary.rb` in the legacy environment:

```ruby
Bparity.boundary do
  observe "Legacy::Slugifier" do
    methods :call
  end
  driver :rspec, files: "spec/**/*_spec.rb"
end
```

Record and synthesize a checked specification bundle while the legacy environment still works:

```bash
bundle exec bparity record --require lib/legacy.rb
bundle exec bparity synthesize --tests 'spec/**/*_spec.rb' --source 'lib/**/*.rb'
```

Commit `.bparity/spec_bundle.yml`. In the replacement environment, map its abstract operations to the new API:

```ruby
Bparity.adapter(spec: ".bparity/spec_bundle.yml") do
  subject "Slugifier" do
    construct { NewSlugService }
    operation "#call" do
      invoke { |service, args, _kwargs| service.generate(text: args.fetch(0)) }
    end
  end
end
```

The verification step requires only the bundle, adapter, and replacement:

```bash
bundle exec bparity verify --require lib/new_slug_service.rb
```

Reports support `markdown`, `json`, `junit`, and `html`. A changed bundle checksum is rejected; intentional incompatibilities must be declared with `waive` in the adapter.

Run a bounded exhaustive comparison while both implementations are available:

```bash
bundle exec bparity prove --level f2 --scope size=3,depth=2 \
  --require lib/legacy.rb --require lib/replacement.rb
```

The result uses `no_difference_found`, `difference_found`, or `inconclusive`; it always includes the enumerated case count, scope, assumptions, and excluded inputs.

## Time capsule

Run `bparity init --timecapsule`, vendor endangered gems with `bundle package --all`, and build the generated Dockerfile. Keep the corpus and specification bundle in version control so verification remains possible after the legacy runtime disappears.

## Assurance limits

A successful replay means no difference was found for the recorded examples (F0). It does not prove complete program equivalence. Formal checks always report their bounded scope, assumptions, and unverified areas; solver `unknown` and timeouts are inconclusive, never PASS.

## Development

After checking out the repository, run `bundle install` and `bundle exec rake`.

## Contributing

Bug reports and pull requests are welcome at https://github.com/ydah/bparity.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
