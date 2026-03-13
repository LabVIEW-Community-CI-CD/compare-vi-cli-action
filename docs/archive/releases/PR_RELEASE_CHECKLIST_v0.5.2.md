<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.2 - PR Checklist

## Scope

- VI history comparison suite (aggregate manifests, Dev Dashboard telemetry, expanded tests)
- Branch-policy guard + release automation helpers (`tools/priority/*`)
- Validate `vi-compare-refs` auto-publish workflow and Docker tools parity updates
- Rogue LV/LVCompare cleanup guard enhancements and refreshed docs

## Pre-merge

- [ ] Pester tests (windows-latest) green
- [ ] Pester self-hosted (IntegrationMode include) green
- [ ] Fixture Drift (Windows/Ubuntu) green
- [ ] Validate: mergeability probe passes; branch-policy guard passes; docs link check OK
- [ ] `vi-compare-refs` auto-publish workflow green (artifacts uploaded)
- [ ] No stray LabVIEW.exe / LVCompare after runs (rogue guard summary clean)
- [ ] CHANGELOG.md updated with `## [v0.5.2]` entry and release docs (PR notes/checklist, release notes) aligned
- [ ] README/docs updated where behaviour changed (history suite, release tooling, parity workflows)

## Post-merge

- [ ] Tag v0.5.2 on main
- [ ] Monitor release workflows / `vi-compare-refs` auto-publish run
- [ ] Track follow-ups: history ingestion dashboards, additional Docker parity validation, release branch back-merge
