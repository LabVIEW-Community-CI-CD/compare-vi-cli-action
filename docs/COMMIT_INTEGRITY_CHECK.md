# Commit Integrity Check

Issues: `#743`, `#774`, `#775`

This document defines the `commit-integrity` contract used to evaluate commit trust posture for PR/queue scopes.

## Workflow Contract

- Workflow: `.github/workflows/commit-integrity.yml`
- Job/check target: `commit-integrity`
- Deterministic artifact:
  - `tests/results/_agent/commit-integrity/commit-integrity-report.json`
  - `tests/results/_agent/commit-integrity/commit-integrity-bypass-ledger.json`
  - Uploaded on every run via `if: always()`
- Drift monitor workflow: `.github/workflows/commit-integrity-drift-monitor.yml`
  - Deterministic artifact:
    - `tests/results/_agent/commit-integrity/commit-integrity-drift-report.json`
  - Runs every 6 hours and on manual dispatch.

## Validation Coverage

The checker evaluates all commits in scope and emits explicit violation categories:

- `unverified-commit`
  - Fails when `commit.verification.verified != true`.
- `unknown-unverified-reason`
  - Fails when an unverified commit has reason `unknown` and the policy toggle is enabled.
- `signature-verification-unavailable`
  - Fails when GitHub reports signature verification service unavailability (`gpgverify_error`,
    `gpgverify_unavailable`) and strict availability is enabled.
- `unauthorized-bot-identity`
  - Fails when a bot-authored commit does not match the configured bot allowlist.
- `missing-author-attribution`
  - Fails when both author login and author email are absent and the policy toggle is enabled.
- `missing-committer-attribution`
  - Fails when both committer login and committer email are absent and the policy toggle is enabled.
- `duplicate-commit-sha`
  - Fails when the same commit SHA appears multiple times in scope and the policy toggle is enabled.
- `empty-headline`
  - Fails when commit message headline is empty and the policy toggle is enabled.
- `headline-too-long`
  - Fails when commit headline length exceeds policy maximum.
- `missing-signature-material`
  - Optional strict mode: fails when a commit is marked verified but signature/payload fields are absent.
- `missing-required-trailer`
  - Fails when no required trailer (for example `Issue: #<n>` or `Refs: #<n>`) is present.
- `invalid-required-trailer-format`
  - Fails when a required trailer key is present but its value does not match the configured pattern.

The report emits deterministic commit ordering (`sha-asc`) so repeated runs over the same commit set preserve output
shape and pass/fail decisions.

## Policy Seam

Policy file: `tools/policy/commit-integrity-policy.json`

- No repository-owner hardcoding is used in runtime logic.
- Bot/source classification is policy-driven by regex:
  - `source_resolution.bot_login_patterns`
  - `source_resolution.bot_email_patterns`
- Additional coverage toggles:
  - `checks.require_bot_allowlist`
  - `checks.require_author_attribution`
  - `checks.require_committer_attribution`
  - `checks.require_non_unknown_reason_for_unverified`
  - `checks.require_signature_verification_available`
  - `checks.require_unique_shas`
  - `checks.require_non_empty_headline`
  - `checks.max_headline_length`
  - `checks.require_signature_material_for_verified`
  - `checks.require_required_trailer`
- Trailer schema contract:
  - `trailer_contract.required_any[].key`
  - `trailer_contract.required_any[].value_pattern`
- Bot identity allowlist contract:
  - `bot_identity_policy.require_allowlist_for_bot_commits`
  - `bot_identity_policy.allowed_bot_logins[]`
  - `bot_identity_policy.allowed_bot_email_patterns[]`
- Bypass governance contract:
  - `exception_governance.allow_bypass`
  - `exception_governance.require_reason_owner_expiry`
  - `exception_governance.remediation_labels[]`
  - `exception_governance.remediation_title_prefix`
  - `exception_governance.remediation_issue_marker`

## Drift Guard

- Contract guard script: `tools/Assert-CommitIntegrityContract.ps1`
- Enforced in:
  - `tools/PrePush-Checks.ps1`
  - `.github/workflows/workflows-lint.yml`
- Guard verifies:
  - workflow/job/check naming
  - deterministic report path contract
  - observed-check entries in policy manifests
  - defork-safe runtime/policy content (no hardcoded owner slugs)

## Rollout Flags

- Repo variable: `COMMIT_INTEGRITY_ENFORCE`
  - `0` (default): observe-only mode (`report.result` still indicates pass/fail; workflow exit remains non-blocking)
  - `1`: enforcing mode (violations fail the job)
- `workflow_dispatch` input `enforce` can override mode for manual runs.
- Temporary bypass metadata variables (all required when bypass is used):
  - `COMMIT_INTEGRITY_BYPASS_REASON`
  - `COMMIT_INTEGRITY_BYPASS_OWNER`
  - `COMMIT_INTEGRITY_BYPASS_EXPIRES_AT` (ISO-8601 UTC recommended)
- Optional bypass variables:
  - `COMMIT_INTEGRITY_BYPASS_TICKET`
  - `COMMIT_INTEGRITY_BYPASS_LABELS` (comma-separated)

## Exception Governance

- Bypass is only accepted when all required metadata exists.
- Expired bypass metadata forces a failing check and routes remediation by opening/commenting an issue.
- Remediation issue routing is deterministic (marker-based dedupe) and uses policy-defined labels/title prefix.
- Every run writes a bypass ledger artifact, including runs where no bypass is requested.

## Local Usage

```bash
node tools/npm/run-script.mjs priority:commit-integrity -- --pr 744 --observe-only
```

```bash
node tools/npm/run-script.mjs priority:commit-integrity -- --pr 744
```

```bash
node tools/npm/run-script.mjs priority:commit-integrity:drift
```

## Drift + SLO Monitoring

- Drift/SLO report source: `tools/priority/slo-metrics.mjs` (workflow scoped to `commit-integrity.yml`).
- Report includes pass/fail/skip telemetry plus MTTR/staleness/gate-regression metrics.
- Breach routing:
  - opens/comments an issue with labels `slo`, `ci`, `governance`, `supply-chain`
  - title prefix: `[SLO] Commit integrity breach`
