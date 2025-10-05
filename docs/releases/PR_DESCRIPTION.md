# Manifest bytes + LVCompare preflight hardening

## Summary

- Replace `minBytes` with exact `bytes` in `fixtures.manifest.json` and schema.
- Refine validator to detect `sizeMismatch` (actual vs recorded bytes), fallback to global `-MinBytes` only when `bytes` missing.
- Harden LVCompare orchestration to avoid UI popups by routing calls through `CompareVI` preflight and adding guards in debug helpers.
- Keep LVCompare-only interface; remove LabVIEW.exe involvement.

## Motivation

- Eliminate ambiguous size policy (`minBytes`) and drift from small file changes.
- Fix fast error popups by preventing LVCompare’s “same filename different directories” dialog and standardizing invocation.
- Improve developer-facing diagnostics and stability for local and CI runs.

## Changes

- Schema: `docs/schemas/fixture-manifest-v1.schema.json` (require `bytes` instead of `minBytes`).
- Manifest: `fixtures.manifest.json` now records `bytes` for `VI1.vi` and `VI2.vi`.
- Generator: `tools/Update-FixtureManifest.ps1` now writes `bytes` from file length.
- Validator: `tools/Validate-Fixtures.ps1`
  - Enforce recorded `bytes` when present → `sizeMismatch` issues.
  - Fallback to global `-MinBytes` only if `bytes` absent.
  - JSON summary gains `summaryCounts.sizeMismatch`.
- Tests adjusted to avoid repo pollution and reflect `bytes` semantics (`$TestDrive` for snapshots, duplicate tests updated).
- Orchestrator: `scripts/On-FixtureValidationFail.ps1` routes drift report LVCompare execution via `CompareVI` (preflight), captures exit code/command/duration, generates HTML report.
- Debug helper: `scripts/Capture-LVCompare.ps1` adds preflight guard and `CreateNoWindow` to reduce UI popups.
- README updated for `sizeMismatch` and policy notes.
- Dispatcher emits `session-index.json` (minimal pointers to summary, manifest, leak report, and compare/report artifacts when present).

## Backwards compatibility

- Additive changes in validator output (new `sizeMismatch`); existing fields preserved.
- Manifest change is breaking for producers that expected `minBytes`; this repository fully migrated.

## Validation

- Local unit run: validator OK, updated tests pass; integration should be run on self-hosted with LVCompare present.
- Manual checks:
  - `tools/Validate-Fixtures.ps1 -Json` → ok=true.
  - Drift orchestrator with `-RenderReport` simulates compare and writes artifacts.

## Follow-ups (separate PR(s))

- Add Session Index (`session-index-v1`) to unify links to pester summary, leak report, drift, loop, compare exec.
- Optional enrichments: pester summary tag/file rollups; runbook per‑phase timings; compare exec diagnostics.

## Risks and mitigations

- Schema consumers of `minBytes` must update (we've updated repo scripts/tests and docs here).
- LVCompare preflight dependability verified via existing CompareVI tests; additional smoke tests can be added.

## Checklist

- [x] Update schemas/manifests/generator/validator
- [x] Update tests to reflect `bytes`
- [x] Harden LVCompare paths (orchestrator, capture)
- [x] README/doc updates
- [ ] CI link check and actionlint (run in validate workflow)
- [ ] Self-hosted integration pass

### Dispatcher Gating (Added)

- Do not start tests if `LabVIEW.exe` is running. The dispatcher attempts a best-effort stop, waits briefly, and aborts fast if still present. This prevents hangs and surfaces a clear signal to the operator to close LabVIEW. Opt-in post-run cleanup for `LVCompare.exe` via `CLEAN_LVCOMPARE=1`.
