# Release v0.5.0 (RC merge)

## Summary
- Session index (`session-index.json`) added with status, summary counts, artifact pointers, run context URLs, and a pre-rendered `stepSummary`.
- New schema: `docs/schemas/session-index-v1.schema.json` and schema-lite validation wired in CI (validate, self-hosted, hosted, smoke, integration-on-label).
- Drift action hardened: reliable `drift-summary.json` discovery (timestamped and direct paths) + debug breadcrumbs; “unknown” status resolved.
- Dispatcher: hard gate on running `LabVIEW.exe`; LVCompare post-run cleanup is opt-in via `CLEAN_LVCOMPARE=1`.
- Artifact manifest includes `session-index.json`; workflows append session index summaries and upload as artifact.
- Manifest size policy migrated `minBytes` → `bytes` (exact).

## Breaking
- `fixtures.manifest.json` now requires `bytes` instead of `minBytes`. Repo tooling and validators updated.

## Checklist
- [x] Version bumped to `0.5.0`
- [x] CHANGELOG updated with 2025-10-05 release
- [x] CI green on RC: drift, validate, pester (self-hosted/hosted), smoke
- [x] Session index schema added and validated in CI
- [x] markdownlint clean
- [x] New/updated tests passing (unit + aggregation artifact tracking)
- [x] Drift “unknown” status resolved (Windows job)
- [ ] Tag `v0.5.0` after merge to `main`
- [ ] Announce + update any external docs if needed

## Post-merge steps
1) Tag `v0.5.0` to trigger "Release on tag":
   - `git tag v0.5.0 && git push origin v0.5.0`
2) Verify GitHub Release populated from CHANGELOG
3) Monitor workflows on `main`
