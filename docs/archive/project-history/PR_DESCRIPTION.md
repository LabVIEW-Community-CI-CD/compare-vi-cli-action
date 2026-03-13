<!-- markdownlint-disable-next-line MD041 -->
# Manifest bytes + LVCompare preflight hardening

## Summary

- Replace `minBytes` with exact `bytes` in `fixtures.manifest.json` and the schema.
- Refine the validator to detect `sizeMismatch` (actual vs recorded bytes) and fall back to the
  global `-MinBytes` only when `bytes` is missing.
- Harden LVCompare orchestration to avoid UI popups by routing calls through `CompareVI` preflight
  and adding guards in debug helpers.
- Keep the LVCompare-only interface; remove direct LabVIEW.exe involvement.

## Motivation

- Eliminate the ambiguous size policy (`minBytes`) and drift from small file changes.
- Fix fast error popups by preventing LVCompare's "same filename different directories" dialog and
  standardizing invocation.
- Improve developer-facing diagnostics and stability for local and CI runs.

## Changes

- Schema: `docs/schemas/fixture-manifest-v1.schema.json` now requires `bytes` instead of `minBytes`.
- Manifest: `fixtures.manifest.json` records `bytes` for `VI1.vi` and `VI2.vi`.
- Generator: `tools/Update-FixtureManifest.ps1` writes `bytes` from file length.
- Validator: `tools/Validate-Fixtures.ps1`
  - Enforces recorded `bytes` when present -> reports `sizeMismatch`.
  - Falls back to the global `-MinBytes` only when `bytes` is absent.
  - JSON summary gains `summaryCounts.sizeMismatch`.
- Tests updated to avoid repo pollution and reflect `bytes` semantics. Uses `$TestDrive` for
  snapshots and updates duplicate tests.
- Orchestrator: `scripts/On-FixtureValidationFail.ps1` routes drift report LVCompare execution through
  `CompareVI` preflight, captures exit code, command, and duration, and generates an HTML report.
- Debug helper: `scripts/Capture-LVCompare.ps1` adds a preflight guard and `CreateNoWindow` to reduce
  UI popups.
- README updated for `sizeMismatch` and policy notes.
- Dispatcher emits `session-index.json` with pointers to the summary, manifest, leak report, and
  compare/report artifacts.

## Backwards compatibility

- Additive changes in validator output (new `sizeMismatch`); existing fields are preserved.
- Manifest change is breaking for producers that expected `minBytes`; this repository is fully
  migrated.

## Validation

- Local unit run: validator OK, updated tests pass; integration should run on self-hosted with
  LVCompare present.
- Manual checks:
  - `tools/Validate-Fixtures.ps1 -Json` -> ok=true.
  - Drift orchestrator with `-RenderReport` simulates compare and writes artifacts.

## Follow-ups (separate PRs)

- Add Session Index (`session-index-v1`) to unify links to the Pester summary, leak report, drift,
  loop, and compare execution.
- Optional enrichments: Pester summary tag/file rollups, runbook per-phase timings, and compare
  execution diagnostics.

## Risks and mitigations

- Schema consumers of `minBytes` must update (repo scripts, tests, and docs are updated here).
- LVCompare preflight dependability verified via existing CompareVI tests; additional smoke tests can
  be added.

## Checklist

- [x] Update schemas, manifests, generator, validator
- [x] Update tests to reflect `bytes`
- [x] Harden LVCompare paths (orchestrator, capture)
- [x] README/doc updates
- [ ] CI link check and actionlint (run in validate workflow)
- [ ] Self-hosted integration pass

### Dispatcher Gating (Added)

- Do not start tests if `LabVIEW.exe` is running. The dispatcher attempts a best-effort stop, waits
  briefly, and aborts fast if the process remains. This prevents hangs and surfaces a clear signal to
  the operator to close LabVIEW. Cleanup uses `CLEAN_LV_BEFORE` and `CLEAN_LV_AFTER`; include
  LVCompare with `CLEAN_LV_INCLUDE_COMPARE` (legacy `CLEAN_LVCOMPARE=1`).
