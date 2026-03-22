<!-- markdownlint-disable-next-line MD041 -->
# Security Alert Reconciliation Register

This register tracks only security-alert reconciliation debt that still matters
for RC determinism on current `develop`.

It is intentionally narrower than the general security intake surface. Use it
to keep the live Dependabot / dependency-graph lag explicit without inventing
new remediation work when the repository manifests are already fixed.

## Current State

- The live security intake report remains `platform-stale`.
- The repo manifests are already remediated locally to `js-yaml@4.1.1`.
- GitHub still reports open Dependabot alerts `#3` and `#4` for the same
  package.
- The machine-readable report lives at
  `tests/results/_agent/security/security-intake-report.json`.

## RC-Relevant Finding

### Dependabot / dependency-graph lag after npm remediation

- Why it matters: RC reviewers should not infer an unremediated dependency from
  a stale upstream alert if the repo manifests are already fixed.
- Current seam: `tools/priority/security-intake.mjs` correctly classifies the
  current state as `platform-stale`, but the repository cannot force GitHub to
  reconcile the alert state immediately.
- Evidence surfaces:
  - code: `tools/priority/security-intake.mjs`
  - receipt: `tests/results/_agent/security/security-intake-report.json`
  - manifest proof: `package.json`, `package-lock.json`
  - tests: `tools/priority/__tests__/security-intake.test.mjs`,
    `tools/priority/__tests__/security-intake-schema.test.mjs`
- Follow-up issue: `#1426`

## Exit Criteria

Close or demote this register entry when GitHub Dependabot alerts `#3` and `#4`
either auto-close or stop reporting the repository as `platform-stale`.

If `priority:security:intake` starts failing again because of an API-400 or
similar tooling regression, that is a separate follow-up issue and should not be
folded into the external platform-lag tracker.
