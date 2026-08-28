# bparity

`bparity` captures the observable behavior of a legacy Ruby API, stores it as a portable specification bundle, and checks a structurally different replacement through a small adapter. The legacy dependency is not needed during verification.

## Preserve the legacy environment first

If the old dependency can still run, preserve it before installing anything else:

```bash
bundle package --all
bundle exec bparity init --timecapsule
```

Commit `vendor/cache`, the generated time-capsule Dockerfile, the behavior corpus, and the Specification Bundle. The replacement-side verifier does not load the legacy dependency.

## Installation

```bash
bundle add bparity
```

## Usage

Get an initial boundary proposal from calls made by an exercise script. Discovery observes Ruby calls only; C calls are intentionally excluded:

```bash
bundle exec bparity discover --require lib/legacy.rb --target Legacy::Slugifier script/exercise_legacy.rb
```

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
bundle exec bparity synthesize --coverage .bparity/coverage.json \
  --tests 'spec/**/*_spec.rb' --source 'lib/**/*.rb'
```

If the legacy runtime is already unavailable, extract only executable static assertions and mark the missing runtime evidence as a gap:

```bash
bundle exec bparity synthesize --static-only --tests 'spec/**/*_spec.rb' --source 'lib/**/*.rb'
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

Generate an adapter skeleton when the bundle is ready:

```bash
bundle exec bparity init --from-spec .bparity/spec_bundle.yml
```

Run a bounded exhaustive comparison while both implementations are available:

```bash
bundle exec bparity prove --level f2 --scope size=3,depth=2 \
  --require lib/legacy.rb --require lib/replacement.rb \
  --counterexample-out spec/f2_counterexample_spec.rb
```

The result uses `no_difference_found`, `difference_found`, or `inconclusive`; it always includes the enumerated case count, scope, assumptions, and excluded inputs.

For a stateful subject with `state` projections in both the boundary and adapter, compare learned finite models:

```bash
bundle exec bparity prove --level f3 --equivalence trace \
  --require lib/replacement.rb --export-lts tmp/client
```

F3 reports both model sizes, the learned alphabet, whether exploration was exact, and the shortest distinguishing sequence. `--counterexample-out spec/f3_counterexample_spec.rb` writes that sequence as a regression example. The claim applies only to the projected models.

For an explicitly selected pure Ruby fragment, F4 translates both methods to SMT-LIB 2 and invokes Z3:

```bash
bundle exec bparity prove --level f4 --solver z3 --validate-translation \
  --old-source lib/legacy_math.rb --old-method double \
  --new-source lib/new_math.rb --new-method twice --types Integer \
  --require lib/legacy_math.rb --require lib/new_math.rb \
  --counterexample-out spec/f4_counterexample_spec.rb
```

Translation validation is mandatory. Unsupported Ruby, a translation mismatch, a missing Z3 executable, `unknown`, and solver failures all produce `inconclusive`, never PASS. The implemented fragment covers pure Integer/Boolean/String expressions and conditionals.

Run the five-point adequacy assessment, optionally with the soft `mutant` integration:

```bash
bundle exec bparity adequacy --require lib/replacement.rb
bundle exec bparity adequacy --require lib/replacement.rb --mutant
```

## Assurance limits

A successful replay means no difference was found for the recorded examples (F0). It does not prove complete program equivalence. Formal checks always report their bounded scope, assumptions, and unverified areas; solver `unknown` and timeouts are inconclusive, never PASS. See [Formal assurance limits](docs/formal_assurance_limits.md).

## Reproduce the fixtures

The acceptance suite records, synthesizes, and verifies all five scenarios. Each has a structurally different correct replacement and an intentionally broken replacement:

```bash
bundle exec rspec spec/acceptance_spec.rb
```

## Development

After checking out the repository, run `bundle install` and `bundle exec rake`.

## Contributing

Bug reports and pull requests are welcome at https://github.com/ydah/bparity.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
