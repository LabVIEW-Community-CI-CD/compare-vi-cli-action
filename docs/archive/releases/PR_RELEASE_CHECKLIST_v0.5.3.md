<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.3 - PR Checklist

## Scope

- Staged LVCompare leak telemetry, CLI flag propagation, and timeout overrides.
- Pester/Validate PSGallery hardening (PSResourceGet retry + CDN mirror).
- Staging helper fixes (`AllowSameLeaf`, history smoke adjustments) and docs refresh.
- Validate/compare workflows updated to surface leak columns and resilient installs.

## Pre-merge

- [x] Pester tests (windows-latest) green – `Invoke-PesterTests.ps1` (410 tests) 2025-10-29.
- [x] Pester (self-hosted, IntegrationMode include) green – Integration Runbook Validation run `18916559073`.
- [ ] Fixture Drift (Windows/Ubuntu) green.
- [x] Validate: mergeability probe OK; branch-policy guard OK; docs link check OK – Validate run `18916563077`.
- [x] `vi-compare-refs` auto-publish workflow green – Manual VI Compare (refs) run `18918325616`.
- [x] No stray LabVIEW.exe / LVCompare after runs (session-index leak report clean).

## Post-merge

- [ ] Tag v0.5.3 on `main`.
- [ ] Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) after the tag.
- [ ] Back-merge release branch into `develop` and confirm leak telemetry docs stay in sync.
