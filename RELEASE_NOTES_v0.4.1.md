<!-- markdownlint-disable-next-line MD041 -->
# Release Notes: v0.4.1 (2025-10-03)

> Patch follow-up to preserve existing remote `v0.4.0` while publishing finalized migration scaffolding, runbook schema,
> and verification tooling additions. No history rewrite performed.

## 📌 Summary

v0.4.1 finalizes the artifact naming migration groundwork (`VI1.vi` / `VI2.vi`), introduces an integration runbook
schema + orchestration helper, and adds a structured pre-tag verification script plus a contract test for the identical-
path short-circuit. This release intentionally bumps to a patch version (rather than force-retagging `v0.4.0`) to avoid
rewriting already-published history while still delivering the planned reliability and process tooling.

## 🚀 Highlights

- Integration Runbook automation (`Invoke-IntegrationRunbook.ps1`) + documented runbook (`INTEGRATION_RUNBOOK.md`)
- New JSON schema: `integration-runbook-v1.schema.json`
- Pre-tag verification script (`Verify-ReleaseChecklist.ps1`) producing machine-readable summary
- Short-circuit contract test (`CompareVI.ShortCircuitContract.Tests.ps1`) enforcing `shortCircuitedIdentical` semantics
- Release process helper docs: `PR_NOTES.md`, `TAG_PREP_CHECKLIST.md`, `POST_RELEASE_FOLLOWUPS.md`, `ROLLBACK_PLAN.md`
- README usage examples updated to reference `@v0.4.1`

## ➕ Added

- Runbook orchestration script and runbook documentation
- Runbook JSON schema (`integration-runbook-v1.schema.json`)
- Release checklist verifier (`scripts/Verify-ReleaseChecklist.ps1`)
- Contract test for identical path short-circuit
- Structured release/rollback helper markdown files (not shipped as action outputs, internal process assets)

## ♻️ Changed

- README action references updated to `@v0.4.1`
- Strengthened migration messaging around deprecation timeline (`Base.vi` / `Head.vi`)
- Confirmed `shortCircuitedIdentical` output presence now guarded by explicit test

## 🛠 Fixed

- Eliminated possibility of tagging without migration scaffolding by formalizing pre-tag validation gating

## ⚠️ Migration / Deprecation

Legacy names `Base.vi` / `Head.vi` remain deprecated and still resolve via fallback for this release. Preferred names:
`VI1.vi` / `VI2.vi`. Removal of legacy fallback and expansion of guard tests to scripts + docs targeted for **v0.5.0**.
Begin updating workflows now to avoid disruption.

## 📐 Verification Steps (Recommended for Consumers Upgrading)

1. Update workflow `uses:` lines to `@v0.4.1`.
2. Ensure artifact filenames use `VI1.vi` / `VI2.vi` (or set `LV_BASE_VI` / `LV_HEAD_VI`).
3. (Optional) Execute the integration runbook:

   ```powershell
   pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -All -JsonReport runbook-result.json
   ```

4. Examine `runbook-result.json` for `schema":"integration-runbook-v1"` and `success=true` (if included fields exist).
5. Confirm `shortCircuitedIdentical` output logic in a synthetic workflow by comparing a VI to itself.

## 🧪 Contract / Coverage Additions

| Area | Addition | Purpose |
|------|----------|---------|
| CompareVI | Short-circuit contract test | Ensures identical-path detection stays stable |
| Release | Checklist verifier script | Prevents partial / inconsistent tag creation |
| Runbook | Schema + script | Standardizes environment readiness & documentation |

## 🔭 Roadmap (Forward Looking)

| Target | Planned Item | Status |
|--------|--------------|--------|
| v0.5.0 | Remove legacy Base/Head fallback | Planned |
| v0.5.0 | Expand naming guard to scripts + docs | Planned |
| v0.5.x | Potential additional runbook event enrichment | Under evaluation |
| v0.6.0 | Quantile strategy extensions / advanced percentiles | Backlog |

## 📄 Source Reference

Tag: `v0.4.1` Previous published tag retained: `v0.4.0` (earlier snapshot without runbook & verifier assets)

## ✅ Integrity Notes

- No force-push or remote tag deletion performed.
- Patch version chosen to avoid consumer confusion and retain reproducibility of earlier tag.

## 🧰 Optional Diagnostic Commands

```powershell
# Re-run release verification (should pass with workingDirectoryClean possibly false if dev edits present)
pwsh -File scripts/Verify-ReleaseChecklist.ps1 -Version 0.4.1 -SkipTests

# Run short-circuit scenario manually (adjust path)
pwsh -File scripts/CompareVI.ps1 -Base VI1.vi -Head VI1.vi -FailOnDiff:$false
```

## 🙌 Acknowledgements

Thanks to contributors driving the migration readiness, safety guards, and documentation rigor that made a clean patch
bump feasible without history rewrite.

--- For questions or feedback open an issue with label `release:v0.4.1`.
