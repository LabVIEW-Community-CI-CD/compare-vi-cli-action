<!-- markdownlint-disable-next-line MD041 -->
# ROLLBACK_PLAN.md (v0.4.0)

Concise procedure to revert or mitigate the v0.4.0 release if a blocking regression is reported.

## 1. Triggers

Rollback may be considered if any of the following are observed shortly after release:

- Critical users unable to run compares due to naming migration logic (warnings unexpectedly escalate or fallback
  failure).
- Repeated unexpected non 0/1 exit codes attributable to new preflight or bitness guard logic.
- Widespread discovery failure anomalies traced to soft classification masking deeper issues.
- Loop auto-close / force-kill feature causing deadlocks or data corruption.

## 2. Immediate Containment

1. Open a high-priority issue summarizing the regression (include logs, environment details).
2. If impact is severe, mark release as potentially unstable in README and pin prior stable tag (e.g., add advisory
   banner).
3. Notify stakeholders/community channel with brief status.

## 3. Technical Revert Options

### Option A: Hotfix Patch (Preferred)

- Branch from tag `v0.4.0` → `hotfix/v0.4.1`.
- Revert or adjust minimal offending commits:
  - Naming fallback: ensure legacy `Base.vi` / `Head.vi` resolution intact (already present) or relax warning gating if
    noise causing failures.
  - Bitness guard: temporarily allow 32-bit with warning by wrapping throw in feature flag (env `ALLOW_32BIT_TEMP=1`).
  - Discovery classification: allow enabling strict mode by default if soft mode hides real failures or vice versa.
- Add CHANGELOG entry under `v0.4.1` summarizing corrective actions.
- Tag and release `v0.4.1`.

### Option B: Full Rollback

- If multiple intertwined changes failing, create new tag `v0.3.1` from last v0.3.0 commit (or cherry-pick essential
  non-risk fixes).
- Update GitHub release notes pointing users toward `v0.3.1` pending a re-work.

## 4. Data & Diagnostics Collection

- Capture: `pester-summary.json`, `pester-failures.json`, raw CLI stdout/stderr artifacts, and NDJSON loop events.
- Request user reproduction command with environment variables (`LV_BASE_VI`, `LV_HEAD_VI`, any loop env flags).
- If preflight short-circuit misbehavior suspected, log resolved absolute paths & comparison command.

## 5. Communication Template

```text
Status: Investigating regression in v0.4.0 (ISSUE LINK)
Impact: <summary>
Workaround: Use tag v0.3.0 (or hotfix v0.4.1 when available)
Next Update ETA: <time>
```

## 6. Post-Rollback Follow-Up

- Root cause analysis document (1-page) attached to issue.
- Add regression test preventing recurrence.
- Evaluate whether additional feature flags are needed for staged rollouts (e.g., guard toggles).

## 7. Preventative Hardening Targets

- Add deterministic run log fixture test for auto-close + force-kill sequences.
- Add explicit test validating warning appears only once per legacy artifact use.
- Extend discovery scan tests for edge patterns reported in regression.

## 8. Decision Matrix Snapshot

| Scenario | Action | Tag Path |
|----------|--------|---------|
| Single feature regression (naming warning too noisy) | Hotfix adjust warning gating | v0.4.1 |
| Bitness guard false positives | Hotfix relax guard behind env | v0.4.1 |
| Multiple interdependent failures | Full rollback | v0.3.x line |
| Minor doc mismatch only | Patch docs (no new tag) | n/a |

## 9. Exit Criteria

Rollback considered complete when:

- Mitigating tag published OR advisory posted redirecting to stable version.
- Root cause documented & merged tests cover it.
- Stakeholders acknowledged resolution.

--- Generated: 2025-10-03 (Keep until v0.5.0 or integrate into central operations handbook.)
