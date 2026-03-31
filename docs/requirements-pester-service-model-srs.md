# Pester Service Model SRS

## Document Control

- System: Pester service-model control plane
- Version: `v0.1.0`
- Owner: `#2069`
- Basis: retained fork promotion dossier under `#2078`
- Status: Active

## Scope

- Purpose:
  Specify the trusted Pester control plane that separates context, host
  readiness, selection, execution, and evidence into auditable workflow surfaces.
- In scope:
  Trusted pilot routing, repo/control-plane context certification, self-hosted
  readiness receipts, selection receipts, execution-only dispatcher runs, and evidence
  classification.
- Out of scope:
  Legacy monolithic `test-pester.yml` behavior except where it remains the
  current baseline to compare against.

## Stakeholders

| Role | Need | Priority |
| --- | --- | --- |
| Product | Replace workflow debugging with specified control-plane behavior | High |
| Engineering | Isolate failures by layer instead of chasing one large self-hosted seam | High |
| QA | Trace requirements to workflow-contract tests and evidence artifacts | High |
| Operations | Keep self-hosted ingress access behind trusted routing and explicit receipts | High |

## Requirements

| ID | Requirement | Rationale | Fit Criterion | Verification |
| --- | --- | --- | --- | --- |
| REQ-PSM-001 | The trusted Pester pilot shall admit `workflow_dispatch` and same-owner PR heads carrying the `pester-service-model` label, and shall reject untrusted cross-owner fork heads before self-hosted execution begins. | Trust and admission are part of the subsystem boundary, not incidental workflow behavior. | `pester-service-model-on-label.yml` writes `should_run=true` only for dispatch or trusted same-owner heads, and emits `untrusted-cross-owner-fork` for disallowed heads. | `TEST-PSM-001` |
| REQ-PSM-002 | The context layer shall resolve repository and standing-priority state and emit a context receipt before readiness begins. | Repo/control-plane assumptions must be certified separately from host readiness. | `pester-context.yml` uploads `pester-context.json` with `schema=pester-context-receipt@v1` and a status of `ready`, `warning`, or `blocked`. | `TEST-PSM-002` |
| REQ-PSM-003 | The readiness layer shall certify runner labels, session-lock health, `.NET`, Windows Docker runtime, and LVCompare or idle LabVIEW state, and shall emit a bounded-freshness readiness receipt. | Self-hosted ingress debt must be observable as readiness debt, not hidden inside execution. | `selfhosted-readiness.yml` uploads `selfhosted-readiness.json` with `schema=pester-selfhosted-readiness-receipt@v1`, individual probe outcomes, and `freshnessWindowSeconds=900`. | `TEST-PSM-003` |
| REQ-PSM-004 | The selection layer shall resolve integration mode, include patterns, and dispatcher profile into a selection receipt before self-hosted execution begins. | Pack shaping and dispatcher defaults are control-plane decisions, not execution-side improvisation. | `pester-selection.yml` uploads `pester-selection.json` with `schema=pester-selection-receipt@v1`, the normalized pack selector, and dispatcher profile values. | `TEST-PSM-004` |
| REQ-PSM-005 | The execution layer shall validate context, readiness, and selection receipts before dispatch, run the declared Pester pack without bootstrapping Docker runtimes or core toolchains, and shall emit an execution receipt even when execution is skipped. | Execution should only execute; it must not absorb context, selection, or readiness responsibilities. | `pester-run.yml` refuses to start unless all upstream receipts are ready, calls `Invoke-PesterTests.ps1`, uploads raw results when produced, and always uploads `pester-run-receipt.json`. | `TEST-PSM-005` |
| REQ-PSM-006 | The evidence layer shall classify `context-blocked`, `selection-blocked`, `readiness-blocked`, `test-failures`, and `seam-defect` explicitly from execution receipts and raw artifacts. | Operators need precise failure classes instead of `missing-summary` ambiguity. | `pester-evidence.yml` reads the execution contract and emits the explicit classification when raw artifacts are missing or execution is skipped. | `TEST-PSM-006` |
| REQ-PSM-007 | The pilot shall remain additive until it proves equivalent or better behavior than the monolithic required gate. | Promotion must follow evidence, not preference. | The service-model knowledgebase and promotion rule state that the legacy required gate remains in place until the pilot is proven. | `TEST-PSM-007` |

## Assumptions

- The repo continues to use GitHub Actions for the Pester control plane.
- Trusted self-hosted ingress proof remains on the upstream environment.

## Constraints

- Cross-owner fork heads shall not drive self-hosted execution.
- Upstream promotion must follow the trusted integration rail and retain a
  reference to the fork dossier that justified the slice.
