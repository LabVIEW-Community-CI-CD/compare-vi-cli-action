<!-- markdownlint-disable-next-line MD041 -->
# Session Index v2 Consumer Migration Matrix

## Scope

Critical consumers are tools that parse session-index payloads to drive CI summaries,
operator dashboards, or developer feedback loops.

## Matrix

| Consumer | Area | v2-first status | v1 fallback | Notes |
| --- | --- | --- | --- | --- |
| `.github/actions/session-index-post/action.yml` | CI post-processing summary | ✅ | ✅ | Reads `session-index-v2.json` first, then `session-index.json`. |
| `tools/Write-SessionIndexSummary.ps1` | Step summary reporting | ✅ | ✅ | Uses shared reader module; emits source and requirement-tagged case counts. |
| `tools/Dev-Dashboard.psm1` | Dashboard telemetry model | ✅ | ✅ | Loads preferred index (v2→v1), surfaces source + requirement coverage fields. |
| `tools/Dev-Dashboard.ps1` | Dashboard terminal/HTML rendering | ✅ | ✅ | Displays index source and requirement coverage when available. |
| `tools/vscode/comparevi-extension/src/extension.ts` | VS Code status updates | ✅ | ✅ | Resolves preferred index path (v2→v1) before status refresh. |
| `.github/workflows/validate.yml` `session-index-v2-contract` | CI contract gate | ✅ | ✅ | Burn-in + enforce toggle validates artifact parity and contract shape. |

## Burn-in tracking

- Required runs for promotion: **10 consecutive successful upstream runs**.
- Regression guard target: **5 consecutive upstream runs without consumer regressions**.
- Promotion evidence source: `validate-session-index-v2-contract/session-index-v2-contract.json`.
- Burn-in triage front door: `burnInReceipt` inside `session-index-v2-contract.json`.
- Deprecation policy and v1 cutover checklist: `docs/SESSION_INDEX_V1_DEPRECATION.md`.

## Remaining non-critical consumers

The following scripts still target `session-index.json` directly and are not currently
classified as critical for v2-first cutover:

- `tools/Update-SessionIndexWatcher.ps1`
- `tools/Update-SessionIndexParity.ps1`
- `tools/Update-FixtureDriftSessionIndex.ps1`
- `tools/Run-SessionIndexValidation.ps1`

These remain compatible through v1 fallback and can be migrated in follow-up work if
criticality changes.
