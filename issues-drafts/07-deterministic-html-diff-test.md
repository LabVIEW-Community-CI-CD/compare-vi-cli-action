# Deterministic HTML diff fragment regression test

**Labels:** tests, reliability

## Summary

Introduce a regression test ensuring the HTML diff summary fragment (when `DiffSummaryFormat Html`) is byte-for-byte stable across runs for the same underlying diff scenario.

## Motivation

- Prevents inadvertent reordering or encoding regressions that break downstream parsing.
- Encodes expectations for HTML entity escaping (&, <, >, ' , ").

## Test Design

1. Simulated loop with injected executor returning exit code 1 for a controlled subset of iterations.
2. Capture generated fragment twice within the same test context (or two sequential invocations) and assert identical bytes.
3. Verify presence & order of list items: VI1, VI2, Diff Iterations, Total Iterations.
4. Inject special characters in file paths (temp copies) to assert proper encoding.

## Acceptance Criteria

- [ ] New test file `CompareLoop.HtmlDiffDeterminism.Tests.ps1` added.
- [ ] Fails if ordering or encoding changes.
- [ ] Passes in simulation mode (no real LVCompare required).
- [ ] Uses existing module without introducing new public API surface.

## Risks

- Platform-specific path normalization differences (mitigate by normalizing or using portable temp paths).
