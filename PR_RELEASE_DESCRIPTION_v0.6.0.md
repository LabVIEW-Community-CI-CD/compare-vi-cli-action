<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.0 - Summary & Checklist

## Summary

- Auto-config helpers: `tools/New-LVCompareConfig.ps1` + `tools/Run-LocalDiffSession.ps1`, new VS Code tasks, stateless
  option, archived artifacts.
- Compare harness defaults: `Run-HeadlessCompare`, `Run-DX`, `TestStand-CompareHarness`, `Run-StagedLVCompare`,
  CompareLoop now default to full-detail noise; `-NoiseProfile legacy` remains available.
- Documentation: README, Usage Guide, troubleshooting, and investigation notes updated; new tests protect the helper.

## Release Artifacts

- Notes: `RELEASE_NOTES_v0.6.0.md`
- Changelog section: `CHANGELOG.md` (`v0.6.0`)
- Docs mirror: `docs/CHANGELOG.md`

## Validation

- [x] Pester tests (windows-latest) - `Invoke-PesterTests.ps1`, 2025-11-02.
- [x] Pester tests (self-hosted include) - `Invoke-PesterTests.ps1 -IntegrationMode include`, 2025-11-02.
- [ ] Validate workflow (release/v0.6.0) - `Validate` workflow (workflow_dispatch) on `release/v0.6.0`.
- [ ] Fixture Drift validation (Windows + Ubuntu) for `release/v0.6.0`.
- [ ] `vi-compare-refs` workflow (release/v0.6.0) - ensure latest run green.
- [ ] Session-index leak report clean - `tools/Detect-RogueLV.ps1 -FailOnRogue`.

## Post-Tag Tasks

- Tag v0.6.0 on `main`.
- Fast-forward `develop` from `release/v0.6.0` (handled via `node tools/npm/run-script.mjs release:finalize -- 0.6.0`) and track any follow-up
  documentation.
- Publish GitHub release notes summarising the auto-config flow and new compare defaults.
