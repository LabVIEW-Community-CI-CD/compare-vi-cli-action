# Operator Remediation Playbooks

This runbook defines deterministic remediation steps for the top recurring failure classes in standing-priority lanes.

## Failure Class 1: Validate lane cancellation / timeout drift

### Trigger signature (validate timeout drift)

- Validate run contains cancelled jobs, especially lane jobs with abrupt timeout signatures.
- Common signal: windows lane cancellation before expected runtime envelope.

### Deterministic actions (validate timeout drift)

1. Capture run evidence (run URL, cancelled job name, step timing range).
2. Compare timeout values in workflow vs observed lane runtime.
3. Apply minimal timeout correction in workflow.
4. Re-dispatch Validate on the same branch/ref.
5. Confirm rerun reaches terminal `success` for previously cancelled lane.

### Evidence template (validate timeout drift)

- `run_id_before`, `run_id_after`
- `job_name`
- `timeout_before`, `timeout_after`
- `result_after`

## Failure Class 2: Required-check hydration gap / temporary mismatch

### Trigger signature (required-check hydration gap)

- Required-context verdict reports missing checks immediately after merge.
- Follow-up run eventually hydrates and aligns all required contexts.

### Deterministic actions (required-check hydration gap)

1. Capture current required-context verdict payload.
2. Dispatch one rerun of Validate using the same head ref.
3. Recompute required-context verdict after rerun completion.
4. If still mismatched, escalate to branch-protection drift diagnostics.
5. If aligned, post closing evidence comment and resume normal flow.

### Evidence template (required-check hydration gap)

- `head_sha`
- `matched_before`, `matched_after`
- `missing_before`, `missing_after`
- `rerun_id`

## Failure Class 3: Standing-priority routing/label drift

### Trigger signature (standing-priority routing drift)

- Standing issue cache/router points to stale issue.
- `standing-priority` label not aligned with intended active issue.

### Deterministic actions (standing-priority routing drift)

1. Query open `standing-priority` issues in upstream repo.
2. If stale label exists, remove it from closed/superseded issue.
3. Add label to target active issue.
4. Run `priority:sync` to refresh local cache/router artifacts.
5. Post correction note on affected issues for audit traceability.

### Evidence template (standing-priority routing drift)

- `previous_issue`
- `new_issue`
- `router_issue_after`
- `cache_issue_after`

## Operator status reporting

Use the operator summary command to emit lane state, blockers, and trend metrics:

```powershell
pwsh -NoLogo -NoProfile -File tools/priority/Write-OperatorStatusSummary.ps1
```

Default output:

- `tests/results/_agent/operator-status.md`

## Incident evidence references

- Validate cancellation remediation example: [PR #658](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/658)
- Required-context hydration remediation evidence: [Issue #655 comment](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/655#issuecomment-3999591665)
- Standing-priority routing correction evidence: [Issue #664 comment](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/664#issuecomment-4001571220)
