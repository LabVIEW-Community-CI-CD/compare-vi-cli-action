# Release v0.4.0 – PR Notes Helper (Do Not Ship With Final Tag)

This helper file summarizes the key points for PR #41 (release/v0.4.0-rc.1) and can be used to refine the PR description prior to merge/tag. Remove or exclude from packaged artifacts if not desired long-term.

## 1. Summary

Release v0.4.0 centers on:

- Naming migration (Base.vi/Head.vi → VI1.vi/VI2.vi) with runtime warnings & soft fallback.
- Loop resiliency features (graceful auto-close, force kill fallback, stray 32‑bit LVCompare cleanup).
- Bitness & safety guards (PE header check; identical path & same-name preflight guards).
- Expanded dispatcher schemas v1.3.0–v1.7.1 (timing, stability, discovery, outcome, aggregationHints, build timing metric).
- Discovery failure soft classification (non-fatal by default; strict mode opt-in via `DISCOVERY_FAILURES_STRICT=1`).
- Enhanced metrics & outputs (percentiles, histogram, streaming/hybrid quantile strategies, `shortCircuitedIdentical`).

## 2. Key Changes

### Naming Migration

- Preferred artifacts: `VI1.vi` / `VI2.vi` (legacy `Base.vi` / `Head.vi` still accepted this release).
- Guard test (module scope) prevents legacy names from creeping back into module code.
- Runtime `[NamingMigrationWarning]` when legacy names are used.
- Future (v0.5.0): Remove fallback & expand guard to scripts + docs.

### Reliability & Safety

- Auto-close loop with optional force kill (`LOOP_CLOSE_LABVIEW_FORCE=1`).
- Stray 32‑bit LVCompare detection & termination (`lvcompareStrayKill` event).
- PE header bitness validation rejects 32-bit `LVCompare.exe` at canonical path.
- Preflight diff guards: identical absolute path short-circuit + same-filename rejection.

### Telemetry & Metrics

- Loop metrics: average latency, exact & streaming/hybrid percentile strategies, optional histogram.
- JSON NDJSON events: `labviewCloseAttempt`, `lvcompareStrayKill`, `finalStatusEmitted`, `stepSummaryAppended`, etc.
- Action output `shortCircuitedIdentical` surfaces identical-path short-circuit state.

### Dispatcher / Schema Enhancements

- Additive schema versions: v1.3.0–v1.7.1.
  - v1.3.0: timing block.
  - v1.4.0: stability block scaffold.
  - v1.5.0: discovery detail block.
  - v1.6.0: outcome classification block.
  - v1.7.0: aggregationHints block.
  - v1.7.1: `aggregatorBuildMs` timing metric (conditional).
- All schema changes additive; baseline payload unchanged unless switches used.

### Discovery Failures Soft Mode

- Matches no longer auto-fail run unless strict mode enabled.
- Counts & snippets preserved for observability.
- Env opts: `DISCOVERY_FAILURES_STRICT=1` for pre-migration strict parity.

## 3. Migration & Deprecation

| Aspect | Current (v0.4.0) | Future (v0.5.0) |
|--------|------------------|------------------|
| Artifact Names | `VI1.vi` / `VI2.vi` preferred; `Base.vi` / `Head.vi` fallback w/ warning | Remove fallback; fail or block legacy names |
| Guard Scope | Module only | Expand to scripts + docs |
| Runtime Warning | Emitted for legacy usage | Removed after full removal (warning not needed) |
| Schema Keys | `basePath` / `headPath` unchanged | Unchanged |

## 4. Backward Compatibility

- No removed outputs or schema keys.
- Fallback ensures existing workflows remain functional during transition.
- Legacy streaming strategy alias (`StreamingP2`) retained with warning.

## 5. Rollback Plan (If Blocking Issue Found)

1. Create hotfix branch from last stable commit pre-v0.4.0.
2. Revert migration warning block + module guard test (if root cause) and any offending changes.
3. Re-publish as v0.4.1 or retract v0.4.0 (if discovered immediately and minimally adopted).
4. Document rollback rationale in CHANGELOG under Unreleased.
5. Open issue capturing lessons & follow-up mitigation.

## 6. Testing & Validation

- Unit + non-integration suites: PASS (130 tests) with discovery failures soft mode observed but non-fatal.
- Markdown lint: PASS (0 errors).
- Action outputs vs `docs/action-outputs.md`: Synced (includes `shortCircuitedIdentical`).
- Guard test enforcing absence of legacy names in module: PASS.
- Loop single iteration real CLI test prepared (requires canonical path & VI assets).

## 7. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Users ignore migration warning | Delayed adoption; future break at v0.5.0 | Clear warning + CHANGELOG + README migration note |
| Soft discovery mode hides genuine structural errors | Latent test misconfiguration | Metrics/log counts retained; optional strict env toggle |
| Force kill masks LabVIEW/runtime anomalies | Harder RCA on modal issues | Optional flag; events record `forceKill` and `forceKillSuccess` |
| Name fallback removal backlash | Upgrade friction | Advance notice + staged guard expansion |

## 8. Follow-Up Issues To Open Post-Merge

1. Remove artifact fallback & expand guard (scripts/docs) for v0.5.0.
2. Add outcome sub-classification enhancements (e.g., distinguishing discovery vs execution failure weights further).
3. Optional coverage integration for Integration-tagged tests.
4. Documentation pruning & consolidation after migration finalization.
5. Evaluate enabling strict discovery classification by default after stability window.

## 9. Tag Preparation Checklist (Draft)

1. Confirm version refs (`package.json`, action docs) reflect v0.4.0.
2. Regenerate outputs docs (if any change) via `./tools/npm/bin/npm run generate:outputs` (already in sync for this PR).
3. Run full test dispatcher (unit + integration if canonical LVCompare present).
4. Run markdown lint & (optional) actionlint over workflows.
5. Inspect CHANGELOG: ensure v0.4.0 section finalized; remove "Unreleased" placeholders referencing these changes.
6. Create annotated tag: `git tag -a v0.4.0 -m "v0.4.0: naming migration + resiliency"`.
7. Push tag: `git push origin v0.4.0`.
8. Draft GitHub Release referencing PR + migration/deprecation notes + rollback summary.

## 10. Acceptance Criteria Summary

- [x] Legacy names produce warning (not failure).
- [x] Action outputs include `shortCircuitedIdentical` when applicable.
- [x] No schema breaking changes.
- [x] Guard test prevents reintroduction of legacy names in module.
- [x] Markdown hygiene clean.
- [x] Tests green (unit path) & loop logic stable.

## 11. Notes for Reviewers

- Focus on correctness of fallback warning messaging & future timeline clarity.
- Validate no unintended side-effects on exit codes (0 vs 1 mapping preserved).
- Confirm deterministic ordering in HTML/JSON diff & loop summaries unchanged.

---

Generated: 2025-10-03
(Keep or adapt; delete before publishing final release if redundant.)
