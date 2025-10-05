# Release v0.5.0

Highlights

- Deterministic CI on self-hosted Windows
  - Per-ref concurrency with cancel-in-progress, job timeouts
  - Preflight gate: refuse to start if LabVIEW.exe is running; clear error
  - Post-run guard (opt‑in) to snapshot/cleanup and append summary
- Stable session visibility
  - Dispatcher emits `tests/results/session-index.json` with pointers and a ready-to-append `stepSummary`
  - All relevant workflows validate session-index schema (lite) and upload artifact
- Fixture policy and drift/report hardening
  - Manifest now records exact `bytes` instead of `minBytes`; validator enforces `sizeMismatch`
  - Drift orchestrator routes compare via robust `CompareVI` preflight; reporter prefers `compare-exec.json` (Source: execJson)
- YAML hygiene & docs
  - actionlint runs before markdownlint in Validate (always executes)
  - Added AGENTS.md and docs link checker; fixed workflow YAML issues

Upgrade Notes

- If you consume  `fixtures.manifest.json`, migrate parsing from `minBytes` to `bytes`
- No changes to action inputs/outputs; dispatcher JSON artifacts are additive

Validation Checklist

- [ ] Pester (hosted Windows) unit tests green
- [ ] Pester (self‑hosted Windows) with integration enabled passes preflight and runs clean
- [ ] Fixture Drift (Windows/Ubuntu) green; report shows “Source: execJson” when rendered
- [ ] Validate workflow: actionlint OK; docs link check OK (markdownlint may remain policy‑driven)
- [ ] No LabVIEW.exe left open after jobs (guard shows zero or expected cleanup)

Post-Release

- Tag v0.5.0 on main
- Open follow‑ups for composites consolidation and managed tokenizer adoption (separate PRs)
