<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.2 - Summary & Checklist

Summary

- VI history comparison suite with aggregate/per-mode manifests, expanded Pester coverage, and Dev Dashboard telemetry
  so history runs surface actionable context in HTML/JSON reports.
- Branch-policy guard + release automation helpers (`tools/priority/*`) that enforce required checks, manage release /
  feature branches, and streamline standing-priority workflows.
- Validate `vi-compare-refs` auto-publish path, Docker tools parity workflow, and refreshed docs for cross-plane
  PowerShell requirements and feature-branch policy.

Release Artifacts

- Notes: RELEASE_NOTES_v0.5.2.md
- Changelog section: CHANGELOG.md (v0.5.2)

Validation (must be green)

- [ ] Pester tests (windows-latest)
- [ ] Pester (self-hosted, IntegrationMode include)
- [ ] Fixture Drift (Windows/Ubuntu)
- [ ] Validate: mergeability probe OK; branch-policy guard OK; docs link check OK
- [ ] `vi-compare-refs` auto-publish workflow green (artifacts uploaded)
- [ ] No stray LabVIEW.exe after runs (rogue guard summary clean)

Upgrade Notes

- Consumers of history manifests should ingest the new aggregate/per-mode JSON files emitted by
  `tools/Compare-VIHistory.ps1`.
- Release automation scripts (`tools/priority/*`) expect branch-policy guard parity; ensure local `GH_TOKEN` is
  configured when using them.
- Action inputs/outputs unchanged; additional telemetry/artifacts are additive.

Post-merge

- [ ] Tag v0.5.2 on main
- [ ] Monitor release workflows / `vi-compare-refs` auto-publish run
- [ ] Open follow-ups: dashboard ingestion of history suite, wider Docker parity coverage
