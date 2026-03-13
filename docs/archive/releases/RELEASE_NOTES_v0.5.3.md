<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.3

Highlights

- Staged LVCompare telemetry & timeout controls
  - `tools/Run-StagedLVCompare.ps1`, `tools/Run-HeadlessCompare.ps1`, `Invoke-LVCompare.ps1`,
    `scripts/Capture-LVCompare.ps1`, and `tools/LabVIEWCli.psm1` now expose leak toggles and timeout overrides, writing
    `compare-leak.json` per comparison so CI can summarise leak counts without downloading artifacts.
  - `/vi-stage` workflow updates (`pr-vi-staging.yml`, `tools/Summarize-VIStaging.ps1`) include leak totals in the PR
    comment/table to highlight stuck LabVIEW/LVCompare processes.
- PSGallery-resilient Validate/Pester bootstrap
  - Validate’s session-index job resolves Pester through `tools/Get-PesterVersion.ps1`, retries `Install-Module`,
    falls back to `Install-PSResource`, and mirrors `Pester 5.7.1` from the CDN when Gallery is offline.
  - The reusable Pester dispatcher consumes the same hardened installer, keeping self-hosted smoke runs aligned.
- Staging semantics & docs refresh
  - `tools/Stage-CompareInputs.ps1` reports `AllowSameLeaf` when mirroring dependency trees; `Run-HeadlessCompare` and
    `Run-StagedLVCompare` propagate the flag so matching leaf comparisons stay opt-in.
  - Guard tests allow expected VI history smoke references, and docs (Developer Guide, release checklists) cover the new
    leak/timeout environment variables.

Upgrade Notes

- New environment variables (`RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS`, `RUN_STAGED_LVCOMPARE_LEAK_CHECK`,
  `RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS`, `VI_STAGE_COMPARE_FLAGS*`) influence staging behaviour; local scripts
  should set them as needed.
- PSGallery outages no longer break the Validate pipeline, but `tools/Get-PesterVersion.ps1` is now the single source of
  truth—bump it when adopting a newer Pester.
- `/vi-stage` workflow summaries already include leak totals; reviewers can triage leaks from the PR table rather than
  downloading artifacts.

Validation Checklist

- [x] Pester (hosted Windows) – `Invoke-PesterTests.ps1`, 2025-10-29.
- [x] Pester (self-hosted, IntegrationMode include) – Integration Runbook Validation run `18916559073`.
- [ ] Fixture Drift (Windows/Ubuntu).
- [x] Validate workflow (`18916563077`) – mergeability probe OK, branch-policy guard OK, docs link check OK.
- [x] Manual VI Compare refs (`18918325616`) – artifacts uploaded for release branch.
- [x] Session-index leak report clean – no rogue LabVIEW/LVCompare processes.

Post-Release

- Tag `v0.5.3` on `main` once required checks complete.
- Monitor release workflows (`Validate`, `vi-compare-refs`, staging smoke) and ensure leak telemetry renders as expected.
- Back-merge the release branch into `develop`; schedule fixture drift validation if not already executed.
