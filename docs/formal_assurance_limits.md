# Formal assurance limits

`bparity` never reports unrestricted program equivalence. Every formal result has one of three verdicts: `no_difference_found`, `difference_found`, or `inconclusive`. It also carries its scope, assumptions, excluded behavior, and any counterexample.

## Levels

- F0 checks only recorded calls. Unrecorded inputs and operation sequences remain unverified.
- F1 executes declared first-order contracts. A passing result applies only to executed paths.
- F2 enumerates every value in the reported finite domain. Case, time, or domain-construction limits make the result `inconclusive`; they are never described as exhaustive. When the legacy implementation is unavailable, the claim is limited to the declared postconditions and invariants.
- F3 compares projected finite-state models. The report includes both model sizes, the learned alphabet, whether exploration completed, and a reminder that this is a model claim rather than a whole-implementation claim.
- F4 applies only to the declared pure fragment. It requires bounded translation validation before Z3 is consulted. Unsupported Ruby, translation disagreement, solver absence, timeout, or `unknown` invalidates the F4 claim.

## Assumptions

Formal output names its assumptions. H1 freezes the verified class definitions, H3 excludes dynamic evaluation from the verified fragment, H6 models exceptions as outputs, and H7 currently declares single-threaded execution without runtime enforcement. A detected assumption violation invalidates the result.

## Reading a successful result

`no_difference_found` means no counterexample exists in the exact reported scope under the listed assumptions. It says nothing about larger F2 values, unprojected F3 state, operations outside the learned alphabet, unsupported F4 Ruby, concurrency, process effects, timing, GC, or object identity.

Use the five-point assessment alongside the verdict: specification coverage, generated checks, formal reach, mutation constraint strength, and residual risks. Waivers remain visible and require explicit adapter declarations.
