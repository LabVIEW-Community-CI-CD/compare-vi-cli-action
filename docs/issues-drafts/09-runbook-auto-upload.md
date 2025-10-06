# Auto-upload raw CLI artifacts in runbook when in GitHub Actions

**Labels:** automation, enhancement

## Summary

Enhance `Invoke-IntegrationRunbook.ps1` to optionally auto-stage raw CLI output artifacts (stderr/stdout/exit code) when running inside GitHub Actions.

## Motivation

- Streamlines triage of environment/setup issues.
- Reduces manual replay steps for first-time adopters.

## Feature Outline

- Detect `GITHUB_ACTIONS` environment variable.
- New switch: `-UploadArtifacts` (default: off) OR env `RUNBOOK_UPLOAD_ARTIFACTS=1`.
- Produce files: `runbook-lvcompare-stdout.txt`, `runbook-lvcompare-stderr.txt`, `runbook-lvcompare-exitcode.txt`.
- Print guidance block to step summary (if `$GITHUB_STEP_SUMMARY`).

## Acceptance Criteria

- [ ] No behavior change when switch/env not set.
- [ ] When enabled, artifacts created only if compare step executed (skip if short-circuited or prereqs missing).
- [ ] Documentation updated (runbook doc + README reference section).
- [ ] Lint/test pass; simulated test covers artifact presence.

## Risks

- Large stdout sizes (mitigate by truncating > configurable max, e.g., 200KB with notice).
