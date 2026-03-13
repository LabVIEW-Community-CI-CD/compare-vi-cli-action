<!-- markdownlint-disable-next-line MD041 -->
# Self-Hosted Windows Implementation Status

Snapshot of features, workflows, and docs supporting self-hosted Windows runners.

## Core features

- Canonical CLI path enforcement (`scripts/CompareVI.ps1`).
- Structured error handling and step summary outputs.
- PR comment dispatcher (`/run pester-selfhosted`, `/run smoke`).
- Integration/Smoke workflows gated by labels (`test-integration`, `smoke`, `vi-compare`).

## Testing infrastructure

- Unit dispatcher (`tools/Run-Pester.ps1`) for GitHub-hosted runners.
- Root dispatcher (`Invoke-PesterTests.ps1`) for self-hosted runs.
- Step-based invoker module (see ADR 0001).
- Integration suite (requires LabVIEW + LVCompare at canonical path).

## Workflows overview

| Workflow | Purpose |
| -------- | ------- |
| `test-pester.yml` | Unit tests on `windows-latest` |
| `pester-selfhosted.yml` | Integration tests on self-hosted Windows |
| `pester-integration-on-label.yml` | Auto integration when PR labeled `test-integration` |
| `smoke-on-label.yml` | Smoke validation when PR labeled `smoke` |
| `vi-compare-pr.yml` | Full comparison reports (`vi-compare` label) |
| `ci-orchestrated.yml` | Deterministic orchestrated checks (single/matrix) |

## Documentation set

- [`README.md`](../../../README.md) – Quick start + action usage.
- [`docs/runner-setup.md`](../../runner-setup.md) – Runner provisioning.
- [`docs/SELFHOSTED_CI_SETUP.md`](../../SELFHOSTED_CI_SETUP.md) – Detailed setup guide.
- [`docs/E2E_TESTING_GUIDE.md`](../../E2E_TESTING_GUIDE.md) – End-to-end validation.
- [`docs/DEV_DASHBOARD_PLAN.md`](../../DEV_DASHBOARD_PLAN.md) – Telemetry dashboard plan.

## Verification checklist

- Unit + integration workflows succeed on respective runners.
- Command dispatcher responds to PR comments and posts monitoring links.
- Smoke/vi-compare labels trigger expected workflows.
- Markdownlint / actionlint clean.
- HTML reports and provenance artefacts uploaded.

## Next steps / enhancements

- Broader LabVIEW version coverage.
- Enhanced HTML diff visualisation.
- Automated runner health checks/dashboard alerts.
