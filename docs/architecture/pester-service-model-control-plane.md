# Pester Service Model Control Plane

## Overview

- System: Pester service-model control plane
- Purpose:
  Replace the monolithic self-hosted Pester transaction with explicit control
  layers that can be proven, audited, and promoted intentionally.
- Scope:
  Trusted routing, context, selection, readiness, execution, evidence, and the additive
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
| Execution layer | Run the selected Pester pack after validating upstream receipts | GitHub Actions + PowerShell |
| Evidence layer | Classify results, summarize them, and publish operator artifacts | GitHub Actions + PowerShell |

## Component View

| Component | Container | Responsibility |
| --- | --- | --- |
| `pester-service-model-on-label.yml` | Trusted router | Admission control for dispatch and same-owner labeled PRs |
| `pester-context.yml` | Context layer | Repository and standing-priority receipt |
| `pester-selection.yml` | Selection layer | Integration mode, include pattern, and dispatcher profile receipt |
| `selfhosted-readiness.yml` | Readiness layer | Runner labels, session lock, `.NET`, Docker, and LVCompare readiness |
| `pester-run.yml` | Execution layer | Receipt validation, dispatcher invocation, execution contract |
| `pester-evidence.yml` | Evidence layer | Classification, summary, session index, and dashboard publication |

## Deployment View

- Environments:
  GitHub hosted Ubuntu, self-hosted Windows ingress, and the upstream
  integration rail used to prove promotion slices.
- Nodes:
  GitHub Actions runners, self-hosted ingress host, repo filesystem, and receipt
  artifact storage.
- Runtime dependencies:
  GitHub token, standing-priority cache, `dotnet`, Windows Docker runtime,
  LVCompare, Session-Lock scripts, and `Invoke-PesterTests.ps1`.

## Correspondence And Rationale

- Requirement-to-component notes:
  `REQ-PSM-001` maps to the trusted router.
  `REQ-PSM-002` maps to context.
  `REQ-PSM-003` maps to readiness.
  `REQ-PSM-004` maps to selection.
  `REQ-PSM-005` maps to execution.
  `REQ-PSM-006` maps to evidence.
  `REQ-PSM-007` maps to the additive promotion boundary.
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
