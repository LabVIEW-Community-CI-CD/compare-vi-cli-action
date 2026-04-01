# Pester Service Model Test Plan

## Overview

- Release or baseline:
  Pester service-model assurance packet `v0.1.21`
- Owner:
  `#2069` with retained fork basis on `#2078`
- Scope:
  Trusted routing, context receipts, selection receipts, readiness receipts,
  execution-only behavior, named execution packs, durable progress telemetry,
  local replay surfaces, schema-governed retained artifacts, and evidence
  classification for the Pester service model

## Test Items

| Item | Type | Risk | Notes |
| --- | --- | --- | --- |
| `pester-service-model-workflow-contract.test.mjs` | Integration | High | Verifies the workflow split and core receipt/evidence obligations |
| `pester-service-model-local-harness-contract.test.mjs` | Integration | High | Verifies the local execution harness stays aligned to the execution-layer boundary without the workflow shell |
| `Get-PesterResultXmlSummary.Tests.ps1` + `Invoke-PesterExecutionPostprocess.Tests.ps1` | Unit | High | Verifies execution-post can classify truncated, invalid, and missing XML integrity states and repair machine-readable summaries without re-entering dispatch |
| `pester-service-model-quality-workflow-contract.test.mjs` | Integration | Medium | Verifies the coverage gate and docs link-check control-plane workflow |
| `pester-gate.yml` + trusted pilot routing | Workflow | High | Verifies admission and orchestration across layers |
| `pester-selection.yml` selection contract | Workflow | High | Verifies pack shaping and dispatcher-profile resolution leave execution clean |
| `Invoke-PesterTests.ps1` execution contract | Execution | High | Verifies the dispatcher remains the execution engine only |
| `Invoke-PesterExecutionFinalize.ps1` + `Invoke-PesterExecutionPublication.ps1` finalize or publication contract | Execution | High | Verifies summary, manifest, session-index, leak-report, and operator-facing publication leave the dispatcher and are owned by dedicated helpers |
| `Invoke-PesterExecutionPostprocess.ps1` execution-post contract | Execution | High | Verifies XML integrity classification and machine-readable summary repair occur after dispatch |
| `Invoke-PesterExecutionTelemetry.ps1` telemetry contract | Execution | High | Verifies dispatcher events and handshake markers are normalized into a durable telemetry artifact with last-known phase and pack identity |
| `Run-PesterExecutionOnly.Local.ps1` local harness | Execution | High | Mirrors lock, LV guard, fixture prep, dispatcher profile, dispatch, execution-post, and local execution receipt without the workflow shell |
| `Write-PesterSummaryToStepSummary.Tests.ps1` + `Write-PesterSummaryToStepSummary.CompactMode.Tests.ps1` | Unit | High | Verifies failure-detail readers accept current and legacy payload shapes and keep summary/badge output truthful |
| `PesterFailurePayloadShape.Tests.ps1` | Unit | High | Verifies top-failure readers accept current and legacy payload shapes and do not silently drop failure detail |
| `PesterFailureProducerConsistency.Tests.ps1` + finalize degradation coverage | Unit/Execution | High | Verifies execution emits populated canonical failure detail for real failures and repairs empty detail to an explicit unavailable-details state when summary counts are nonzero |
| `TEST-PSM-012` named-pack and execution-group coverage | Contract/Execution | High | Verifies selection receipts, local entrypoints, and evidence retain a named execution-pack or test-group identity instead of relying on `IncludePatterns` alone |
| `TEST-PSM-013` local path-hygiene coverage | Unit/Execution | High | Verifies `PesterPathHygiene.Tests.ps1` and `Run-PesterExecutionOnly.Local.PathHygiene.Tests.ps1` for relocate and block behavior before dispatch |
| `TEST-PSM-014` retained-artifact replay coverage | Integration | High | Verifies `Invoke-PesterEvidenceClassification.Tests.ps1` and `Replay-PesterServiceModelArtifacts.Local.Tests.ps1` can rebuild postprocess, summary, totals, session index, and evidence outputs from mounted artifacts |
| `TEST-PSM-015` side-effect ownership coverage | Contract/Execution | High | Verifies dispatch stops at machine capture while finalize, postprocess, and publication helpers own summary, session-index, artifact manifest, leak-report, and operator-facing publication behavior |
| `TEST-PSM-016` durable progress telemetry coverage | Execution/Integration | High | Verifies long-running execution retains `dispatcher-events.ndjson` plus `pester-execution-telemetry.json`, and replay surfaces can inspect telemetry without rerunning dispatch |
| `TEST-PSM-017` schema-governance coverage | Contract | High | Verifies incompatible receipt or artifact schema changes are rejected explicitly by postprocess, evidence, and replay consumers with `unsupported-schema` classification |
| `TEST-PSM-018` promotion-comparison coverage | Assurance | High | Verifies the release-evidence bundle and promotion dossier retain requirement-to-run comparison evidence for representative named packs versus the current baseline |
| `TEST-PSM-019` named entrypoint coverage | Contract/Execution | High | Verifies common named packs are exposed through stable wrappers or commands instead of only through raw dispatcher arguments |
| `TEST-PSM-020` planned provenance coverage | Assurance/Contract | High | Will verify evidence and promotion outputs retain source raw-artifact, receipt, run, and ref provenance |
| `TEST-PSM-021` operator-outcome coverage | Integration/Assurance | High | Verifies failing gates emit `pester-operator-outcome.json` plus machine-readable classification, reasons, and actionable context before failing the job |
| `TEST-PSM-022` local autonomy-loop coverage | Assurance/Contract | High | Verifies local CI emits a machine-readable ranked backlog and a selected next requirement for LLM-guided local-first development |
| `TEST-PSM-023` autonomy-policy and stop-condition coverage | Assurance/Contract | High | Verifies local autonomy uses explicit policy, active worktree signals, and stop conditions to bound local iteration |
| `TEST-PSM-024` representative retained-artifact replay coverage | Integration/Execution | High | Verifies representative legacy retained artifacts replay locally without throwing and preserve the real evidence classification plus operator outcome |
| `TEST-PSM-025` windows-container surface coverage | Integration/Contract | High | Verifies the local Windows Docker Desktop + NI image surrogate emits an explicit bounded receipt before hosted reruns are chosen, including reachable Windows host bridge use from Unix or WSL coordinators |
| `TEST-PSM-026` proof-check aware autonomy coverage | Assurance/Contract | High | Verifies local CI consumes representative replay and Windows-surface proof checks and reopens implemented requirements when representative proof regresses |
| `TEST-PSM-027` next-step escalation coverage | Assurance/Contract | High | Verifies local CI emits a machine-readable escalation step when the next truthful proof surface is unavailable from the current host |
| `TEST-PSM-028` shared local-program selector coverage | Assurance/Contract | High | Verifies the shared program selector can choose a Pester requirement ahead of sibling escalations and merge the shared Windows Docker Desktop + NI image escalation across packets |
| `TEST-PSM-029` secondary-authority coverage | Workflow/Governance | Medium | Verifies Windows image-backed CI gates use the shared Windows NI proof path as blocking execution truth and that the Pester packet documents itself as secondary on that surface |

## Entry Criteria

- The service-model workflows and contract test are in sync with the declared requirements.
- The local execution harness remains traced to the execution-layer requirement and contract tests.
- The retained fork dossier still matches the mounted upstream promotion slice.

## Exit Criteria

- Workflow-contract tests pass.
- Local harness contract tests pass.
- Hosted packet quality and release-evidence workflows complete.
- Any remaining action items are explicitly accepted before the slice widens
  beyond hosted quality and evidence.
- The local autonomy loop shall stay current with the packet so autonomous work
  does not outrun the requirements baseline.
- The autonomy policy and stop conditions shall stay versioned and visible so
  autonomous work remains bounded instead of improvisational.

## Coverage Targets

| Metric | Target | Evidence |
| --- | --- | --- |
| Workflow contract coverage | All layer responsibilities represented | `tools/priority/__tests__/pester-service-model-workflow-contract.test.mjs` |
| Local harness contract coverage | Local execution slice stays aligned with workflow execution boundaries | `tools/priority/__tests__/pester-service-model-local-harness-contract.test.mjs` |
| Receipt coverage | Context, selection, readiness, execution, and evidence all emit auditable artifacts | assurance report + integration runs |
| Classification coverage | blocked and defect outcomes remain distinguishable | evidence workflow outputs |
| Failure-detail interface coverage | Current and legacy `pester-failures.json` shapes remain readable and truthful under degradation | `tests/Write-PesterSummaryToStepSummary*.ps1`, `tests/PesterFailurePayloadShape.Tests.ps1` |
| Failure-detail producer consistency coverage | Execution never leaves nonzero failure counts without populated detail or an explicit unavailable-details state | `tests/PesterFailureProducerConsistency.Tests.ps1`, `tests/Invoke-PesterExecutionFinalize.Tests.ps1`, `TEST-PSM-011` |
| Named execution-pack coverage | Pack or group identity remains explicit across selection, execution, local entrypoints, and evidence | `TEST-PSM-012` |
| Local path-hygiene coverage | Local results and session-lock roots avoid synced or externally managed directories unless explicitly relocated or blocked | `TEST-PSM-013` |
| Retained-artifact replay coverage | Postprocess, summary, totals, session index, and evidence can be rebuilt locally from retained artifacts | `TEST-PSM-014` |
| Side-effect ownership coverage | Dispatcher does not reacquire finalize, postprocess, or evidence responsibilities | `TEST-PSM-015` |
| Durable progress telemetry coverage | Long-running execution emits inspectable progress outside live log streaming | `TEST-PSM-016` |
| Schema-governance coverage | Readers reject incompatible receipt or artifact schema drift explicitly with `unsupported-schema` classification | `TEST-PSM-017` |
| Promotion-comparison coverage | Promotion packets retain requirement-to-run comparison evidence on representative named packs | `tools/priority/__tests__/pester-service-model-release-evidence-provenance.test.mjs`, `tools/priority/__tests__/pester-service-model-release-evidence-workflow-contract.test.mjs`, `TEST-PSM-018` |
| Named entrypoint coverage | Common operator workflows use stable named wrappers instead of raw dispatcher arguments only | `TEST-PSM-019` |
| Provenance coverage | Derived evidence and promotion views can be traced back to the exact raw inputs and runs they came from | `tests/Invoke-PesterEvidenceProvenance.Tests.ps1`, `tests/Replay-PesterServiceModelArtifacts.Local.Tests.ps1`, `tools/priority/__tests__/pester-service-model-release-evidence-provenance.test.mjs`, `TEST-PSM-020` |
| Operator-outcome coverage | Failing gates remain explainable without manual log archaeology | `TEST-PSM-021` |
| Local autonomy-loop coverage | Local CI yields a ranked requirement backlog and selected next requirement for LLM-guided work | `tools/priority/pester-service-model-local-ci.mjs`, `TEST-PSM-022` |
| Autonomy-policy coverage | Local CI exposes explicit local-vs-hosted boundaries and active worktree signals | `tools/priority/pester-service-model-autonomy-policy.json`, `TEST-PSM-023` |
| Representative retained-artifact replay coverage | A reduced live-run fixture replays through current postprocess, evidence, and operator-outcome contracts without crashing on compatibility debt | `tests/Replay-PesterServiceModelRepresentativeArtifact.Tests.ps1`, `TEST-PSM-024` |
| Windows-container surface coverage | The local Docker Desktop Windows + pinned NI image surface is probed explicitly before hosted reruns are chosen, and reachable Windows host bridges are consumed before host-unavailable escalation is emitted | `tests/Invoke-PesterWindowsContainerSurfaceProbe.Tests.ps1`, `tests:windows-surface:probe`, `TEST-PSM-025` |
| Proof-check aware autonomy coverage | Local CI reopens implemented requirements when representative local proof regresses and records advisory surface status | `tools/priority/pester-service-model-local-ci.mjs`, `TEST-PSM-026` |
| Next-step escalation coverage | Local CI emits `pester-service-model-next-step.json` with a governed escalation packet when the next truthful proof surface is unavailable from the current host | `tools/priority/pester-service-model-local-ci.mjs`, `docs/schemas/pester-service-model-next-step-v1.schema.json`, `TEST-PSM-027` |
| Shared local-program selector coverage | Shared local CI emits `comparevi-local-program-next-step.json`, chooses requirement work ahead of sibling packet escalations, and merges the shared Windows Docker Desktop + NI image handoff across packets | `tools/priority/__tests__/comparevi-local-program-ci.test.mjs`, `tools/priority/comparevi-local-program-ci.mjs`, `docs/schemas/comparevi-local-program-next-step-v1.schema.json`, `TEST-PSM-028` |
| Secondary-authority coverage | The Pester packet documents Windows image-backed CI proof as authoritative on the shared Windows NI surface, and `vi-binary-gate.yml` no longer routes through `pester-reusable.yml` | `tools/priority/__tests__/pester-service-model-workflow-contract.test.mjs`, `tools/priority/__tests__/pester-service-model-local-harness-contract.test.mjs`, `TEST-PSM-029` |
| Packet coverage gate | Retained `coverage.xml` and named PR coverage gate | `.github/workflows/pester-service-model-quality.yml` |
| Promotion bundle retention | Hosted bundle retains the minimal promotion handoff | `.github/workflows/pester-service-model-release-evidence.yml` |

## Reporting

- CI artifacts:
  upstream integration runs plus hosted release-evidence outputs
- Test report location:
  `tools/priority/__tests__/pester-service-model-workflow-contract.test.mjs`
  `tools/priority/__tests__/pester-service-model-local-harness-contract.test.mjs`
- Defect tracking link:
  `#2069` and `#2078`
