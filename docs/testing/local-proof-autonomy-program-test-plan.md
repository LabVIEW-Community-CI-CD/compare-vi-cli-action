# CompareVI Local Proof Autonomy Program Test Plan

## Document Control

- System: CompareVI local proof autonomy program
- Version: `v0.1.1`
- Status: Active

## Verification Matrix

| Test ID | Coverage | Layer | Priority | Notes |
| --- | --- | --- | --- | --- |
| `TEST-LPAP-001` packet aggregation and requirement ranking coverage | Assurance/Program | High | Verifies the program consumes sibling packet next-step artifacts and ranks requirement work ahead of escalation work |
| `TEST-LPAP-002` shared-surface escalation merge coverage | Assurance/Program | High | Verifies shared escalations to the same external surface collapse into one bounded handoff packet |
| `TEST-LPAP-003` post-local promotion escalation coverage | Assurance/Program | High | Verifies the program emits a machine-readable promotion escalation instead of `null` when local packets are complete |
| `TEST-LPAP-004` concurrent bundle workspace safety coverage | Assurance/Program | High | Verifies packet-local CI surfaces use run-scoped audit bundle roots instead of deleting a shared `surface-bundle` workspace |

## Entry Criteria

- The program knowledgebase, SRS, and RTM stay in sync.
- The sibling packet local-CI entrypoints stay available through `package.json`.

## Exit Criteria

- Program selector tests pass.
- The program CI report and next-step artifacts validate against their schemas.
- When packet-local work is complete, the program emits a bounded post-local escalation instead of a silent terminal `null`.
