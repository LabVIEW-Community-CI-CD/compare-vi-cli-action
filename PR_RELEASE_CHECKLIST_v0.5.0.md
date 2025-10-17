<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.0 - PR Checklist

## Scope

- Deterministic self-hosted workflows (concurrency, preflight, guard)
- Session index emission/validation across workflows
- Fixture manifest bytes policy + validator updates
- Drift/report hardening (execJson as source)

## Pre-merge

- [ ] Pester tests (windows-latest) green
- [ ] Pester self-hosted (IntegrationMode include) green
- [ ] Fixture Drift (Windows/Ubuntu) green
- [ ] Validate: actionlint passes; docs link check OK
- [ ] No stray LabVIEW.exe after runs (guard summary clean)
- [ ] CHANGELOG and RELEASE_NOTES_v0.5.0.md updated and accurate
- [ ] README/docs updated where behavior changed

## Post-merge

- [ ] Tag v0.5.0 on main
- [ ] Monitor release workflows/artifacts
- [ ] Open follow-ups: composites consolidation; managed tokenizer adoption
