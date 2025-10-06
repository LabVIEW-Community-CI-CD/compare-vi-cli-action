# Add optional code coverage support for Integration-tagged tests

**Labels:** testing, enhancement

## Summary

Investigate adding opt-in code coverage collection for Pester Integration-tagged tests without imposing default runtime overhead.

## Rationale

- Visibility into test exercise depth.
- Potential gating metric (minimum coverage threshold) for integration layer.

## Approach Sketch

- Evaluate: native PS line instrumentation vs external tool (e.g., OpenCover via PowerShell, if compatible).
- Add dispatcher switch: `-EnableCoverage`.
- Emit coverage artifact (e.g. `coverage-summary.json` + raw format if external tool used).

## Acceptance Criteria

- [ ] Coverage disabled by default (no overhead when off).
- [ ] Enabling emits deterministic artifact(s) documented in README.
- [ ] Unit test or synthetic integration test asserts artifact presence when enabled (mock CLI allowed).
- [ ] No failures if tool not available—graceful skip with warning.

## Out of Scope

- Enforcing coverage thresholds (separate follow-up issue if desired).

## Risks

- Added runtime overhead; must remain acceptable (<10% baseline increase when disabled).
