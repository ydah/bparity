<div align="center">
  <h1>bparity</h1>
  <p><strong>Capture legacy Ruby behavior and verify replacement implementations</strong></p>
  <p>
    <a href="https://github.com/ydah/bparity/actions/workflows/main.yml"><img src="https://github.com/ydah/bparity/actions/workflows/main.yml/badge.svg" alt="CI"></a>
    <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-ruby.svg" alt="Ruby Version">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
  </p>
</div>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#how-it-works">How It Works</a> ·
  <a href="#formal-assurance">Formal Assurance</a> ·
  <a href="#commands">Commands</a>
</p>

---

`bparity` records the observable behavior of a legacy Ruby API as a portable Specification Bundle, then checks a replacement through the same behavioral boundary. The replacement may use completely different classes, methods, and argument shapes, and verification does not need the retired dependency.

## Features

- Records arguments, returns, errors, yields, mutations, state, and external calls
- Extracts specification evidence from RSpec, Minitest, and Ruby source
- Maps structurally different replacements through a small Adapter DSL
- Replays recorded traces and checks generated property inputs
- Compares finite-state models and emits distinguishing sequences
- Performs bounded exhaustive checks and opt-in Z3 proofs
- Reports structured diffs, provenance, waivers, assumptions, and residual risks
- Exports Markdown, JSON, JUnit XML, and HTML reports

## Installation

Add the GitHub source to your Gemfile:

```ruby
gem "bparity", github: "ydah/bparity", branch: "main"
```

Then install:

```bash
bundle install
```

### Requirements

- Ruby 3.1+
- RSpec or Minitest in the legacy environment
- Z3 only when running F4 proofs
- `mutant` only when requesting mutation analysis

## Quick Start

### 1. Preserve the legacy environment

Do this first while the retired dependency still runs:

```bash
bundle package --all
bundle exec bparity init --timecapsule
```

Commit `vendor/cache`, `.bparity/timecapsule`, the behavior corpus, and the generated Specification Bundle.

### 2. Define the observation boundary

Edit `.bparity/boundary.rb`:

```ruby
Bparity.boundary do
  observe "Legacy::Slugifier" do
    methods :call
  end

  driver :rspec, files: "spec/**/*_spec.rb"
end
```

To discover candidate public methods from an exercise script:

```bash
bundle exec bparity discover \
  --require lib/legacy.rb \
  --target Legacy::Slugifier \
  script/exercise_legacy.rb
```

### 3. Record and synthesize

Run the legacy test suite once, then freeze the result as a checked bundle:

```bash
bundle exec bparity record --require lib/legacy.rb
bundle exec bparity synthesize \
  --coverage .bparity/coverage.json \
  --tests 'spec/**/*_spec.rb' \
  --source 'lib/**/*.rb'
```

If the legacy runtime is already unavailable, extract static assertions instead:

```bash
bundle exec bparity synthesize --static-only \
  --tests 'spec/**/*_spec.rb' \
  --source 'lib/**/*.rb'
```

Static-only bundles mark the missing runtime evidence as a gap.

### 4. Map the replacement

Edit `.bparity/adapter.rb` when the new API differs from the legacy API:

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

### 5. Verify

The replacement-side command needs only the bundle, Adapter, and replacement:

```bash
bundle exec bparity verify --require lib/new_slug_service.rb
```

Run additional conformance runners when their inputs are available:

```bash
bundle exec bparity verify \
  --require lib/new_slug_service.rb \
  --runners replay,property,model \
  --format html \
  --out tmp/bparity.html \
  --fail-under 100
```

For same-named classes with compatible public methods, direct replay works without an Adapter file. An explicitly supplied but missing Adapter path is always an error.

## How It Works

1. **Discovery** identifies the public legacy boundary.
2. **Recording** captures observable behavior while the original tests run.
3. **Synthesis** combines runtime traces, static assertions, invariants, coverage gaps, and finite-state models.
4. **Adaptation** maps abstract operations to the replacement API.
5. **Verification** replays examples and generated inputs against the replacement.
6. **Reporting** shows differences, provenance, formal scope, assumptions, waivers, and remaining risk.

The Specification Bundle is implementation-independent and protected by a checksum. Intentional incompatibilities must be declared as Adapter waivers; editing the bundle to hide a difference is rejected.

## Formal Assurance

| Level | Check | Claim |
|---|---|---|
| F0 | Trace replay | Recorded examples match |
| F1 | Contract and property checks | Executed inputs satisfy declared predicates |
| F2 | Bounded exhaustive comparison | No difference exists in the reported finite domain |
| F3 | Finite-state model comparison | Projected learned models conform |
| F4 | Translation-validated Z3 proof | No difference exists in the supported pure fragment under reported assumptions |

Formal results use `no_difference_found`, `difference_found`, or `inconclusive`. They always include scope, assumptions, and excluded behavior. Timeouts, solver `unknown`, truncated domains, and translation mismatches never become PASS results.

### Bounded exhaustive comparison

```bash
bundle exec bparity prove --level f2 --scope size=3,depth=2 \
  --require lib/legacy.rb \
  --require lib/replacement.rb \
  --counterexample-out spec/f2_counterexample_spec.rb \
  --promote-invariants
```

If the legacy class is unavailable, F2 can check the replacement against declared postconditions and invariants. Case or time limits make the result `inconclusive`, never exhaustive.

### Finite-state comparison

```bash
bundle exec bparity prove --level f3 --equivalence trace \
  --require lib/replacement.rb \
  --export-lts tmp/client \
  --counterexample-out spec/f3_counterexample_spec.rb
```

F3 reports model sizes, the learned alphabet, exploration completeness, and the shortest distinguishing sequence. Its claim applies to the projected models, not the complete implementations.

### Z3 proof

```bash
bundle exec bparity prove --level f4 --solver z3 --validate-translation \
  --old-source lib/legacy_math.rb --old-method double \
  --new-source lib/new_math.rb --new-method twice \
  --types Integer \
  --require lib/legacy_math.rb \
  --require lib/new_math.rb \
  --counterexample-out spec/f4_counterexample_spec.rb
```

Translation validation is mandatory. The supported fragment covers pure Integer, Boolean, and String expressions with conditionals. See [Formal assurance limits](docs/formal_assurance_limits.md) for the exact boundaries.

## Commands

| Command | Purpose |
|---|---|
| `bparity init` | Generate boundary and Adapter templates |
| `bparity discover` | Suggest a boundary from observed Ruby calls |
| `bparity record` | Capture behavior from the legacy test suite |
| `bparity synthesize` | Build a checked Specification Bundle |
| `bparity verify` | Run replay, property, model, or differential checks |
| `bparity prove` | Run F2, F3, or F4 formal checks |
| `bparity adequacy` | Report coverage, formal reach, and optional mutation strength |
| `bparity diff` | Compare two Specification Bundles |
| `bparity explain` | Show the provenance of one specification item |
| `bparity assumptions` | List verification assumptions and enforcement |

Run the five-point adequacy assessment with:

```bash
bundle exec bparity adequacy --require lib/replacement.rb
bundle exec bparity adequacy --require lib/replacement.rb --mutant
```

## Development

```bash
bundle install
bundle exec rake
```

The acceptance suite records, synthesizes, and verifies five fixtures with both correct and intentionally broken replacements:

```bash
bundle exec rspec spec/acceptance_spec.rb
```

## Contributing

Bug reports and pull requests are welcome at https://github.com/ydah/bparity.

## License

Released under the [MIT License](https://opensource.org/licenses/MIT).
