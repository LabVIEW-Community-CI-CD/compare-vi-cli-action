# Release Notes: v0.5.0 (2025-10-03)

> Minor release focusing on PR review experience, centralized debugging, and simplified argument handling.

## Summary

v0.5.0 introduces a polished pull-request diff experience, a single consolidated debug artifact validated by a lightweight schema, and a preview mode to inspect LVCompare argument tokenization without execution. It also promotes `VI1.vi`/`VI2.vi` as the canonical fixtures and updates docs and CI hygiene.

## Highlights

- PR diff snippet and HTML report generation helper, plus a PR body updater for sticky sections
- Orchestrator debug JSON emitted by the fixture-drift composite and uploaded every run
- New JSON schema: `fixture-drift-orchestrator-debug-v1.schema.json` with schema-lite validation
- Minimal Preview Mode: `-PreviewArgs` and `LV_PREVIEW` to show tokenization without invoking LVCompare
- Actionlint workflow added; markdown lint coverage maintained

## Added

- `scripts/Generate-PullRequestCompareReport.ps1` with `-Base`, `-Head`, `-LvCompareArgs` support
- `scripts/Update-PullRequestBody.ps1` to manage sticky PR sections (unit tests included)
- `docs/schemas/fixture-drift-orchestrator-debug-v1.schema.json` and CI validation step
- Developer Guide section on Orchestrator Debug JSON

## Changed

- README and Usage Guide examples updated to `@v0.5.0`
- Composite fixture-drift action now emits and uploads `orchestrator-debug.json` and gates PR updates by policy
- `scripts/CompareVI.ps1` and `module/CompareLoop` support Preview Mode

## Fixed

- Stabilized argument tokenization tests (backslash normalization and helper scoping)
- Hardened composite behavior to avoid non-critical failures (PR update errors do not fail the job)

## Migration Notes

- Canonical fixtures: continue using `VI1.vi` and `VI2.vi`
- Ensure LVCompare is installed at the canonical path for non-preview runs
- For PR updates, grant `pull-requests: write` in workflows

## Verification

- Unit tests: all green
- Integration tests (with real LVCompare): green
- Markdown lint: 0 errors

## Tagging Guidance

- Update workflow `uses:` lines to `@v0.5.0`
- Optionally run the dispatcher locally:

```powershell
./Invoke-PesterTests.ps1
```

---
For issues related to this release, open an issue with label `release:v0.5.0`.
