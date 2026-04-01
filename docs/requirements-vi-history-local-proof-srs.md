# VI History Local Proof SRS

## Document Control

- System: VI History local proof control plane
- Version: `v0.1.3`
- Owner: `#2069`
- Status: Active

## Scope

- Purpose:
  Specify the local-first VI History proof surfaces that should be used before
  another GitHub run is chosen.
- In scope:
  Windows workflow replay, local refinement profiles, local operator-session
  wrappers, workflow-readiness envelopes, and local autonomy or escalation
  selection for VI History proof.
- Out of scope:
  Downstream release pinning, hosted PR comment publication, and release-train
  promotion beyond the local proof surfaces.

## Stakeholders

| Role | Need | Priority |
| --- | --- | --- |
| Product | Treat VI History as an explicit sibling proof surface, not a side effect of Pester work | High |
| Engineering | Reproduce VI History seams locally before spending GitHub CI time | High |
| QA | Trace local proof surfaces to requirements, receipts, and replay contracts | High |
| Operations | Reuse the same Windows Docker Desktop + NI image surface intentionally across adjacent local proof lanes | High |

## Requirements

| ID | Requirement | Rationale | Fit Criterion | Verification |
| --- | --- | --- | --- | --- |
| REQ-VHLP-001 | A stable local Windows workflow-replay lane shall exist for `vi-history-scenarios-windows`, and it shall emit a workflow-grade receipt plus compare artifacts before another hosted rerun is chosen. | The Windows VI History lane is one of the most expensive places to discover breakage, so it needs a bounded local replay surface first. | `priority:workflow:replay:windows:vi-history` drives `windows-workflow-replay-lane.mjs --mode vi-history-scenarios-windows`, emits `windows-workflow-replay-lane@v1`, retains compare capture, report, runtime snapshot, stdout, and stderr paths, and can be launched through a reachable Windows host bridge from a Unix or WSL coordinator. | `TEST-VHLP-001` |
| REQ-VHLP-002 | Stable VI History local refinement profiles shall exist for `proof`, `dev-fast`, `warm-dev`, and `windows-mirror-proof`, and those profiles shall emit canonical local receipts and benchmarks. | Local VI History work should use declared profiles instead of ad hoc Docker invocations so the proof plane stays repeatable and comparable. | `Invoke-VIHistoryLocalRefinement.ps1` exposes the declared profiles, pins `windows-mirror-proof` to `nationalinstruments/labview:2026q1-windows`, and writes `local-refinement.json`, `local-refinement-benchmark.json`, and `vi-history-review-loop-receipt.json` under `tests/results/local-vi-history/<profile>/`. | `TEST-VHLP-002` |
| REQ-VHLP-003 | Stable VI History local operator-session wrappers shall exist for common refinement profiles so maintainers do not need to drive the refinement helper directly for common review loops. | Operator-facing wrappers make the local proof plane easier to use consistently and cheaper to automate. | `history:local:operator:review`, `history:local:operator:warm`, and `history:local:operator:windows-mirror:proof` invoke `Invoke-VIHistoryLocalOperatorSession.ps1`, which returns the canonical local operator-session contract. | `TEST-VHLP-003` |
| REQ-VHLP-004 | The VI History lane state shall be normalized into a workflow-readiness envelope that records Windows and Linux lane status, failure class, lifecycle, and a bounded recommendation. | Multi-lane VI History proof should end in an explicit machine-readable decision surface instead of free-form log archaeology. | `Write-VIHistoryWorkflowReadiness.ps1` writes `vi-history/workflow-readiness@v1` with lane lifecycle, verdict, recommendation, and source artifact paths. | `TEST-VHLP-004` |
| REQ-VHLP-005 | Local assurance CI shall synthesize the VI History local-proof packet into a machine-readable report, ranked backlog, and next step for local-first development. | VI History needs the same bounded local guidance as the Pester packet instead of remaining outside the autonomy control plane. | A local VI History CI entrypoint emits a report, summary, and next-step artifact grounded in the packet, code refs, and proof checks. | `TEST-VHLP-005` |
| REQ-VHLP-006 | When the next truthful VI History proof surface is unavailable from the current host, local assurance CI shall emit a machine-readable escalation step to the shared `windows-docker-desktop-ni-image` surface instead of a human-only advisory. | VI History and Pester share the same Windows Docker Desktop + NI image infrastructure; the local loop should hand off to that shared surface explicitly. | When the Windows workflow replay surface is unavailable after native or bridge-backed Windows surface checks, the local VI History CI emits `vi-history-local-next-step.json` with the blocked requirement, governing requirement, required surface `windows-docker-desktop-ni-image`, current host state, receipt path, and recommended commands. | `TEST-VHLP-006` |
| REQ-VHLP-007 | The VI History packet shall participate in the shared local proof program selector so it can be chosen explicitly against sibling packets and share merged escalation handoffs when the required surface is common. | VI History should be an explicit sibling proof surface, not an orphan packet that a human has to reconcile manually against Pester. | `priority:program:local-ci` consumes `vi-history-local-next-step.json`, can select a VI History requirement ahead of sibling packet escalations, and merges shared `windows-docker-desktop-ni-image` escalations from VI History and Pester into one `comparevi-local-program-next-step.json` handoff. | `TEST-VHLP-007` |
| REQ-VHLP-008 | The VI History packet shall govern a clone-backed live-history iteration candidate, and the initial candidate shall be `ni/labview-icon-editor:Tooling/deployment/VIP_Pre-Uninstall Custom Action.vi`. | Retained fixtures and public proof seeds are useful, but they do not replace a real repo clone with actual git lineage when local maintainers need to iterate on VI History behavior. | `tools/priority/vi-history-live-candidate.json` declares the candidate id, repo slug, repo URL, default branch, clone-root override contract, target VI path, and minimum git-history expectation for `VIP_Pre-Uninstall Custom Action.vi`. | `TEST-VHLP-008` |
| REQ-VHLP-009 | Local assurance CI shall validate that the governed live-history candidate clone exists locally, contains the target VI, and exposes real git history before Windows replay or hosted proof is chosen as the next step. | There is no truthful VI History local proof for a live-history target if the repo clone, target VI, or commit history are missing. | `vi-history-local-ci.mjs` emits `vi-history-live-candidate-readiness.json` with `ready`, `missing-clone`, `missing-target`, `missing-history`, or `git-failed`, records clone and history facts, and emits a machine-readable clone-preparation escalation when the governed candidate is unavailable. | `TEST-VHLP-009` |
