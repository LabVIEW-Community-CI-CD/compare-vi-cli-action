# Commit Integrity Check

Issue: `#743`

This document defines the `commit-integrity` contract used to evaluate commit trust posture for PR/queue scopes.

## Workflow Contract

- Workflow: `.github/workflows/commit-integrity.yml`
- Job/check target: `commit-integrity`
- Deterministic artifact:
  - `tests/results/_agent/commit-integrity/commit-integrity-report.json`
  - Uploaded on every run via `if: always()`

## Validation Coverage

The checker evaluates all commits in scope and emits explicit violation categories:

- `unverified-commit`
  - Fails when `commit.verification.verified != true`.
- `unknown-unverified-reason`
  - Fails when an unverified commit has reason `unknown` and the policy toggle is enabled.
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
  - `checks.require_author_attribution`
  - `checks.require_committer_attribution`
  - `checks.require_non_unknown_reason_for_unverified`
  - `checks.require_unique_shas`
  - `checks.require_non_empty_headline`
  - `checks.max_headline_length`
  - `checks.require_signature_material_for_verified`
  - `checks.require_required_trailer`
- Trailer schema contract:
  - `trailer_contract.required_any[].key`
  - `trailer_contract.required_any[].value_pattern`

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

## Local Usage

```bash
node tools/npm/run-script.mjs priority:commit-integrity -- --pr 744 --observe-only
```

```bash
node tools/npm/run-script.mjs priority:commit-integrity -- --pr 744
```
