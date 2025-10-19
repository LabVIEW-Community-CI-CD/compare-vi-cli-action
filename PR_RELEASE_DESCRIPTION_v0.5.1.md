<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.1 – Summary & Checklist

Summary

- Deterministic CI on self-hosted Windows (concurrency, timeouts, preflight, guard)
- Session index artifacts across workflows with schema-lite validation and stepSummary
- Fixture manifest bytes policy (`bytes` replaces `minBytes`), validator `sizeMismatch`
- Drift/report hardening (execJson source), YAML + docs hygiene (actionlint early)

Release Artifacts

- Notes: RELEASE_NOTES_v0.5.1.md
- Changelog section: CHANGELOG.md (v0.5.1)

Validation (must be green)

- [ ] Pester tests (windows-latest)
- [ ] Pester (self-hosted, IntegrationMode include)
- [ ] Fixture Drift (Windows/Ubuntu)
- [ ] Validate: actionlint OK; docs link check OK
- [ ] No stray LabVIEW.exe (guard summary)

Upgrade Notes

- Consumers of fixtures.manifest.json must read `bytes` instead of `minBytes`
- Action inputs/outputs unchanged; new JSON artifacts are additive

Post-merge

- [ ] Tag v0.5.1 on main
- [ ] Monitor release workflows/artifacts
- [ ] Open follow-ups: workflow composites; managed arg tokenizer adoption

