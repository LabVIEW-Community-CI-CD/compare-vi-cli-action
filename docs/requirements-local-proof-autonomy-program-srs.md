# CompareVI Local Proof Autonomy Program SRS

## Document Control

- System: CompareVI local proof autonomy program
- Version: `v0.1.1`
- Owner: `#2069`
- Status: Active

## Scope

- Purpose:
  Specify the shared local control plane that ranks sibling packet work and
  emits the next truthful step for autonomous development.
- In scope:
  Packet aggregation, requirement ranking, shared-surface escalation merging,
  and post-local promotion escalation.
- Out of scope:
  Packet-internal execution semantics for Pester, VI History, or Windows host
  bootstrap.

## Stakeholders

| Role | Need | Priority |
| --- | --- | --- |
| Product | One machine-readable next step across local proof packets instead of manual interpretation | High |
| Engineering | Autonomous development should keep moving from packet work to proof promotion without a human translation layer | High |
| QA | Trace program-level ranking and escalation behavior to explicit requirements and tests | High |

## Requirements

| ID | Requirement | Rationale | Fit Criterion | Verification |
| --- | --- | --- | --- | --- |
| REQ-LPAP-001 | The local proof autonomy program shall consume sibling packet-local next-step artifacts and rank requirement work ahead of escalation work. | Autonomous development needs one machine-readable next step across packets, and local requirement closure should happen before external escalation. | `comparevi-local-program-ci.mjs` consumes packet-local reports and next-step artifacts from Pester, VI History, and Windows shared-surface packets, and requirement work outranks escalation work. | `TEST-LPAP-001` |
| REQ-LPAP-002 | The local proof autonomy program shall merge shared escalations to the same external proof surface into one bounded handoff packet. | Duplicate escalations to the same Windows or hosted surface create ambiguity and wasted operator cycles. | When multiple packets require the same external surface, the program emits one merged escalation packet preserving packet identities, governing requirements, proof checks, and recommended commands. | `TEST-LPAP-002` |
| REQ-LPAP-003 | When all tracked packet-local requirements are implemented and no packet-local escalation remains, the local proof autonomy program shall emit a machine-readable promotion escalation instead of `null`. | Autonomous development stalls if the selector stops at “nothing left locally” without identifying the next proof plane. | `comparevi-local-program-next-step.json` emits a bounded escalation naming the post-local proof surface, governing requirement, packet set, suggested loop, and stop conditions when local packet work is complete. | `TEST-LPAP-003` |
| REQ-LPAP-004 | Packet-local CI and the shared program selector shall use run-scoped audit-surface bundle workspaces so concurrent local invocations do not corrupt or delete each other’s evidence bundles. | Autonomous development should tolerate overlapping packet and program invocations without surfacing `ENOTEMPTY` or bundle-deletion races. | Packet-local CI scripts materialize audit surfaces beneath run-scoped `surface-bundle/run-*` roots, and concurrent packet/program invocations can overlap without deleting a shared bundle directory. | `TEST-LPAP-004` |
