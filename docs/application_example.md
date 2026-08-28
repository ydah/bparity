# Application example

The repository's five fixture scenarios are the reference application:

1. `01_pure_function` records a slugifier that calls a retired transliterator and exercises replay and F2.
2. `02_stateful_client` maps a stateful legacy client to a differently shaped session API.
3. `03_external_boundary` verifies the replacement's interaction with an external boundary, not only its return value.
4. `04_intentional_divergence` demonstrates that an undeclared change fails and an explicit adapter waiver is reported as `WAIVED`.
5. `05_formal_negative` changes only a state transition; replay and F3 detect it and F3 emits a distinguishing sequence.

Run the complete application check with:

```bash
bundle exec rspec spec/acceptance_spec.rb
```

The acceptance process launches each CLI phase in a fresh Ruby process. This also demonstrates that verification needs the Specification Bundle, adapter, and replacement only; the legacy dependency is loaded solely while recording.
