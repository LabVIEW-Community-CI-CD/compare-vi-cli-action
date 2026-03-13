<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.3 - Summary & Checklist

Summary

- Staged LVCompare leak telemetry & timeout controls  
  `Run-StagedLVCompare`, `Run-HeadlessCompare`, `Invoke-LVCompare`, and `scripts/Capture-LVCompare.ps1` now accept leak
  toggles and timeout overrides; results include `compare-leak.json`, surfaced in `/vi-stage` workflow summaries.
- PSGallery-resilient Validate/Pester bootstrap  
  Validate’s session-index job and the reusable Pester dispatcher share a hardened installer: PSGallery retry,
  PSResourceGet fallback, and CDN mirror for Pester 5.7.1 to keep comparisons running during gallery outages.
- Staging semantics & docs refresh  
  `Stage-CompareInputs.ps1` propagates `AllowSameLeaf`, guard tests tolerate expected VI history smoke references, and
  the developer/release docs describe the new leak/timeout environment variables.

Release Artifacts

- Notes: `RELEASE_NOTES_v0.5.3.md`
- Changelog section: `CHANGELOG.md` (`v0.5.3`)

Validation (must be green)

- [x] Pester (hosted Windows) – `Invoke-PesterTests.ps1`, 2025-10-29.
- [x] Pester (self-hosted, IntegrationMode include) – Integration Runbook Validation run `18916559073`.
- [ ] Fixture Drift (Windows/Ubuntu) – TODO.
- [x] Validate workflow (`18916563077`): mergeability probe, branch-policy guard, docs lint.
- [x] Manual VI Compare refs (`18918325616`) – artifacts uploaded.
- [x] Session-index leak report clean – no rogue LabVIEW/LVCompare after staging runs.

Upgrade Notes

- New environment knobs (`RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS`, `RUN_STAGED_LVCOMPARE_LEAK_CHECK`, etc.) control leak
  reporting and timeout behaviour; update local scripts accordingly.
- PSGallery outages no longer block Validate/Pester, but CI now expects `tools/Get-PesterVersion.ps1` to remain the
  source of truth for version bumps.
- `/vi-stage` workflow summaries include leak totals; reviewers should rely on the table rather than downloading raw
  artifacts.

Post-Release

- Tag v0.5.3 on `main`.
- Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) and confirm leak telemetry renders in PR
  summaries.
- Back-merge `release/v0.5.3` into `develop` and track any follow-ups (fixture drift run, additional leak toggles).
