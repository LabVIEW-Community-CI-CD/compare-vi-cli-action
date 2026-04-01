# Pester Service Model Control Plane

## Overview

- System: Pester service-model control plane
- Purpose:
  Replace the monolithic self-hosted Pester transaction with explicit control
  layers that can be proven, audited, and promoted intentionally.
- Scope:
  Trusted routing, context, selection, readiness, execution, local replay,
  representative replay compatibility, local Windows-container surrogate proof,
  evidence, execution observability, local autonomy guidance, and the additive
  promotion boundary.

## Stakeholders And Concerns

| Stakeholder | Concern | Viewpoint |
| --- | --- | --- |
| Product | The Pester plane should be an engineered subsystem, not a debugging tangle. | Governance |
| Engineering | Each failure should localize to one layer with one receipt chain. | Execution |
| QA | Requirements, tests, and receipts need end-to-end traceability. | Verification |
| Operations | Self-hosted ingress must stay protected behind trusted routing and readiness contracts. | Runtime |

## Context View

- External actors:
  Maintainers, trusted same-owner PR heads, `workflow_dispatch`, and the
  self-hosted ingress runner.
- Upstream systems:
  Standing-priority issue state, release workflows, and the legacy required
  Pester gate.
- Downstream systems:
  Execution receipts, evidence artifacts, dashboards, and promotion decisions.

## Container View

| Container | Responsibility | Technology |
| --- | --- | --- |
| Trusted router | Decide whether the pilot is allowed to run and which ref it should use | GitHub Actions YAML |
| Context layer | Certify repository slug and standing-priority control-plane assumptions | GitHub Actions + Node |
| Selection layer | Resolve the declared pack and dispatcher profile into a receipt | GitHub Actions + PowerShell |
| Readiness layer | Certify self-hosted ingress runtime state and host dependencies | GitHub Actions + PowerShell |
| Execution layer | Run the selected Pester pack after validating upstream receipts and hand off finalize/publication side effects to dedicated helpers | GitHub Actions + PowerShell |
| Evidence layer | Classify results, summarize them, and publish operator artifacts | GitHub Actions + PowerShell |
| Local replay surface | Rebuild non-host-dependent layers from retained artifacts without the workflow shell | PowerShell + retained artifacts |
| Observability surface | Preserve durable progress and schema-governed trace artifacts across long-running execution | PowerShell + retained artifacts |
| Provenance surface | Retain lineage from derived views back to raw execution inputs and runs | Retained artifacts + documentation packet |
| Windows-container surrogate surface | Bound local Docker Desktop Windows + NI image proof before hosted reruns | PowerShell + Docker Desktop |
| Local autonomy surface | Rank unresolved requirements and emit the next bounded local-first step, including escalations when the required proof surface is unavailable | Node.js + assurance packet |
| Autonomy policy surface | Constrain local-vs-hosted escalation and active-worktree interpretation | JSON policy + Node.js |

## Component View

| Component | Container | Responsibility |
| --- | --- | --- |
| `pester-service-model-on-label.yml` | Trusted router | Admission control for dispatch and same-owner labeled PRs |
| `pester-context.yml` | Context layer | Repository and standing-priority receipt |
| `pester-selection.yml` | Selection layer | Integration mode, include pattern, and dispatcher profile receipt |
| `tools/PesterExecutionPacks.ps1` | Selection layer | Canonical named execution-pack catalog and refinement resolution |
| `selfhosted-readiness.yml` | Readiness layer | Runner labels, session lock, `.NET`, Docker, and LVCompare readiness |
| `pester-run.yml` | Execution layer | Receipt validation, dispatcher invocation, execution contract |
| `tools/PesterFailurePayload.ps1` | Execution layer | Canonical failure-detail payload contract and unavailable-details normalization |
| `tools/Invoke-PesterExecutionFinalize.ps1` | Execution layer | Finalize-owned summary, session-index, artifact-manifest, compare-report, and leak-report side effects |
| `tools/Invoke-PesterExecutionPublication.ps1` | Execution layer | Operator-facing step-summary, session-summary, and diagnostics publication outside the dispatcher |
| `tools/Invoke-PesterExecutionTelemetry.ps1` | Execution layer | Durable telemetry normalization from dispatcher events and handshake markers into a stable inspection contract |
| `tools/PesterServiceModelSchema.ps1` | Execution/Evidence/Replay layers | Shared schema-governance helper for retained receipts and derived artifacts |
| `pester-evidence.yml` | Evidence layer | Classification, summary, session index, and dashboard publication |
| `tools/Invoke-PesterEvidenceClassification.ps1` | Evidence layer | Shared classification contract for hosted evidence and local replay |
| `tools/Invoke-PesterOperatorOutcome.ps1` | Evidence layer | Shared operator-outcome contract for machine-readable gate status, reasons, and next-action guidance |
| `tools/Invoke-PesterEvidenceProvenance.ps1` | Evidence/Replay layers | Shared provenance contract for exact source artifacts, receipt identity, run context, and derived evidence outputs |
| `tools/Write-PesterTotals.ps1` | Evidence layer | Shared totals contract for hosted evidence and local replay |
| `tools/Run-PesterExecutionOnly.Local.ps1` | Local replay surface | Local-first execution harness |
| `tools/Replay-PesterServiceModelArtifacts.Local.ps1` | Local replay surface | Rebuild retained postprocess, totals, session index, and evidence outputs from mounted artifacts |
| `dispatcher-events.ndjson` + execution trace files | Observability surface | Durable runtime progress and post-run inspection anchor |
| Release-evidence bundles, promotion dossiers, and `pester-service-model-promotion-comparison.json` | Provenance surface | Retained comparison and lineage packet for promotion decisions |
| `tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1` | Windows-container surrogate surface | Emit bounded readiness or advisory status for Docker Desktop Windows engine plus the pinned NI Windows image |
| `pester-service-model-local-ci.mjs` | Local autonomy surface | Machine-readable ranked backlog, next requirement guidance, and next-step escalation packet |
| `pester-service-model-autonomy-policy.json` | Autonomy policy surface | Versioned local-vs-hosted decision policy for autonomous iteration |

## Deployment View

- Environments:
  GitHub hosted Ubuntu, self-hosted Windows ingress, and the upstream
  integration rail used to prove promotion slices.
- Nodes:
  GitHub Actions runners, self-hosted ingress host, repo filesystem, and receipt
  artifact storage.
- Runtime dependencies:
  GitHub token, standing-priority cache, `dotnet`, Windows Docker runtime,
  LVCompare, Session-Lock scripts, unsynchronized local workspace roots, and
  `Invoke-PesterTests.ps1`.

## Correspondence And Rationale

- Requirement-to-component notes:
  `REQ-PSM-001` maps to the trusted router.
  `REQ-PSM-002` maps to context.
  `REQ-PSM-003` maps to readiness.
  `REQ-PSM-004` maps to selection.
  `REQ-PSM-005` maps to execution.
  `REQ-PSM-006` maps to evidence.
  `REQ-PSM-007` maps to the additive promotion boundary.
  `REQ-PSM-012` maps to selection plus explicit execution-pack entrypoints.
  `REQ-PSM-013` maps to `tools/PesterPathHygiene.ps1`, local harness path
  hygiene, and session-lock safety before dispatch.
  `REQ-PSM-014` maps to
  `tools/Replay-PesterServiceModelArtifacts.Local.ps1`,
  `tools/Invoke-PesterEvidenceClassification.ps1`, and local replay of
  retained postprocess and evidence layers.
  `REQ-PSM-015` maps to the dispatch/finalize/postprocess/evidence split.
  `REQ-PSM-016` maps to durable execution telemetry.
  `REQ-PSM-017` maps to schema-governed retained artifacts and readers,
  including explicit `unsupported-schema` outcomes for postprocess, evidence,
  and local replay.
  `REQ-PSM-018` maps to `pester-service-model-promotion-comparison.json`,
  release-evidence bundles, and representative baseline comparison rendered into
  the promotion dossier.
  `REQ-PSM-019` maps to stable operator-facing named pack entrypoints.
  `REQ-PSM-020` maps to `pester-evidence-provenance.json`,
  `release-evidence-provenance.json`, and
  `promotion-dossier-provenance.json` across evidence, local replay, and
  promotion views.
  `REQ-PSM-021` maps to operator-explainable gate outcomes, including
  `pester-operator-outcome.json` and shared summary or top-failure rendering
  from the same outcome contract.
  `REQ-PSM-022` maps to the local autonomy loop that selects the next bounded
  requirement slice.
  `REQ-PSM-023` maps to the explicit autonomy policy and stop-condition surface.
  `REQ-PSM-024` maps to representative retained-artifact replay
  compatibility, including schema-lite summary repair and legacy receipt
  tolerance.
  `REQ-PSM-025` maps to the bounded local Windows-container surrogate for
  Docker Desktop Windows engine plus the pinned NI Windows image.
  `REQ-PSM-026` maps to proof-check aware autonomy that reopens implemented
  requirements when representative replay regresses.
  `REQ-PSM-027` maps to the machine-readable next-step escalation packet that
  hands off to the required proof surface when the current host cannot satisfy
  it.
- Decision rationale:
  The service model exists to separate concerns and make failures classifiable by
  layer instead of inferred from one coupled self-hosted run.
- Promotion rationale:
  The upstream packet is promoted from a retained fork dossier, but the
  upstream slice itself remains hosted-first until that evidence justifies a
  broader change.
- Known tradeoffs:
  The system gains more artifacts and receipts, but those are the mechanism that
  makes the control plane auditable.

## ADR Index

- ADR-2078-PSM-001: Model the Pester plane as a specified layered subsystem.
