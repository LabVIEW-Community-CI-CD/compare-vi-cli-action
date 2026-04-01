# VI History Local Proof Test Plan

## Document Control

- System: VI History local proof control plane
- Version: `v0.1.5`
- Status: Active

## Verification Matrix

| Test ID | Coverage | Layer | Priority | Notes |
| --- | --- | --- | --- | --- |
| `TEST-VHLP-001` local Windows workflow replay coverage | Contract/Replay | High | Verifies the governed `vi-history-scenarios-windows` replay lane emits a bounded receipt and compare artifact paths, including bridge-backed Windows launch from Unix or WSL coordinators |
| `TEST-VHLP-002` local refinement profile coverage | Execution/Local | High | Verifies `proof`, `dev-fast`, `warm-dev`, and `windows-mirror-proof` local refinement behavior and retained receipts |
| `TEST-VHLP-003` local operator-session coverage | Operator/Local | High | Verifies local operator-session wrappers consume the refinement helper and emit canonical local session contracts |
| `TEST-VHLP-004` workflow-readiness envelope coverage | Evidence/Decision | High | Verifies the VI History workflow-readiness envelope captures lane lifecycle, verdict, and recommendation |
| `TEST-VHLP-005` local autonomy-loop coverage | Assurance/Contract | High | Verifies local VI History CI emits a report, ranked backlog, and next-step artifact |
| `TEST-VHLP-006` next-step escalation coverage | Assurance/Contract | High | Verifies local VI History CI emits a machine-readable escalation step to the shared Windows Docker Desktop + NI image surface only after native or reachable bridge-backed Windows checks cannot satisfy it |
| `TEST-VHLP-007` shared local-program selector coverage | Assurance/Contract | High | Verifies the shared program selector can choose VI History requirement work explicitly and merge the shared Windows Docker Desktop + NI image escalation across sibling packets |
| `TEST-VHLP-008` clone-backed live-history candidate governance coverage | Assurance/Contract | High | Verifies the packet names `ni/labview-icon-editor` plus `Tooling/deployment/VIP_Pre-Uninstall Custom Action.vi` as the governed clone-backed live-history candidate |
| `TEST-VHLP-009` live-history candidate readiness coverage | Assurance/Contract | High | Verifies local VI History CI validates clone presence, target path presence, and git history, then emits a bounded clone-preparation escalation when the candidate is unavailable |
| `TEST-VHLP-010` explicit Windows replay next-step coverage | Assurance/Contract | High | Verifies local VI History CI emits `vi-history-windows-workflow-replay` as the next step when the shared Windows surface and live-history candidate are ready, instead of launching the replay lane during packet selection |
| `TEST-VHLP-011` bounded Windows replay lifecycle coverage | Contract/Replay | High | Verifies the governed Windows workflow replay lane terminates or fails closed within bounded helper-process timeouts and still emits a replay receipt on timeout |
| `TEST-VHLP-012` replay receipt consumption coverage | Assurance/Contract | High | Verifies local VI History CI treats an existing passing `vi-history-scenarios-windows` replay receipt as satisfied local replay proof and advances beyond replay re-selection |

## Entry Criteria

- The VI History local-proof packet docs and RTM stay in sync.
- The Windows replay lane, local refinement helper, operator-session helper, and workflow-readiness helper stay on disk at the declared paths.

## Exit Criteria

- Contract tests and PowerShell tests covering the packet pass.
- The local VI History CI emits a machine-readable next step.
- The clone-backed live-history candidate is governed explicitly.
- If the current host cannot satisfy the Windows replay lane, the next step is an explicit escalation packet rather than a prose-only advisory.

## Traceability Notes

| Coverage | Proof | Reference |
| --- | --- | --- |
| Local Windows workflow replay coverage | `windows-workflow-replay-lane.mjs` exposes `vi-history-scenarios-windows` replay, supports reachable Windows host bridge launch, and validates its receipt | `tools/priority/__tests__/windows-workflow-replay-lane.test.mjs`, `TEST-VHLP-001` |
| Local refinement profile coverage | `Invoke-VIHistoryLocalRefinement.ps1` emits profile-specific receipts, benchmarks, and review-loop artifacts | `tests/VIHistoryLocalAcceleration.Tests.ps1`, `TEST-VHLP-002` |
| Local operator-session coverage | `Invoke-VIHistoryLocalOperatorSession.ps1` wraps refinement into a local operator-facing contract | `tests/VIHistoryLocalOperatorSession.Tests.ps1`, `TEST-VHLP-003` |
| Workflow-readiness coverage | `Write-VIHistoryWorkflowReadiness.ps1` emits `vi-history/workflow-readiness@v1` | `tests/Write-VIHistoryWorkflowReadiness.Tests.ps1`, `TEST-VHLP-004` |
| Local autonomy-loop coverage | Local VI History CI emits report, next step, and proof-check reasoning | `tools/priority/__tests__/vi-history-local-ci.test.mjs`, `TEST-VHLP-005` |
| Next-step escalation coverage | Local VI History CI emits a shared Windows-surface escalation packet only after native or bridge-backed Windows checks fail or remain non-ready | `tools/priority/__tests__/vi-history-local-ci.test.mjs`, `TEST-VHLP-006` |
| Shared local-program selector coverage | Shared local CI emits `comparevi-local-program-next-step.json`, selects VI History explicitly when it owns the next requirement, and merges the shared Windows surface handoff across packets | `tools/priority/__tests__/comparevi-local-program-ci.test.mjs`, `tools/priority/comparevi-local-program-ci.mjs`, `docs/schemas/comparevi-local-program-next-step-v1.schema.json`, `TEST-VHLP-007` |
| Clone-backed live-history candidate governance coverage | The governed candidate manifest names `ni/labview-icon-editor` and `Tooling/deployment/VIP_Pre-Uninstall Custom Action.vi` explicitly | `tools/priority/__tests__/vi-history-local-proof-contract.test.mjs`, `tools/priority/vi-history-live-candidate.json`, `TEST-VHLP-008` |
| Live-history candidate readiness coverage | Local VI History CI emits `vi-history-live-candidate-readiness.json` and escalates clone preparation when the governed target is unavailable | `tools/priority/__tests__/vi-history-local-ci.test.mjs`, `tools/priority/vi-history-local-ci.mjs`, `docs/schemas/vi-history-live-candidate-v1.schema.json`, `docs/schemas/vi-history-live-candidate-readiness-v1.schema.json`, `TEST-VHLP-009` |
| Explicit Windows replay next-step coverage | Local VI History CI emits `vi-history-local-next-step.json` pointing at `priority:workflow:replay:windows:vi-history` when the packet is ready for live replay, instead of invoking the replay lane during selector execution | `tools/priority/__tests__/vi-history-local-ci.test.mjs`, `tools/priority/__tests__/vi-history-local-proof-contract.test.mjs`, `tools/priority/vi-history-local-ci.mjs`, `TEST-VHLP-010` |
| Bounded Windows replay lifecycle coverage | `windows-workflow-replay-lane.mjs` enforces bounded helper-process timeouts and still writes `windows-workflow-replay-lane@v1` when a timeout occurs | `tools/priority/__tests__/windows-workflow-replay-lane.test.mjs`, `tools/priority/windows-workflow-replay-lane.mjs`, `TEST-VHLP-011` |
| Replay receipt consumption coverage | `vi-history-local-ci.mjs` consumes a passing `vi-history-scenarios-windows` replay receipt and stops re-emitting the same replay escalation as the next step | `tools/priority/__tests__/vi-history-local-ci.test.mjs`, `tools/priority/vi-history-local-ci.mjs`, `TEST-VHLP-012` |
