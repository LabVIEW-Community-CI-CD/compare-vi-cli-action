# Pester Service Model Test Plan

## Overview

- Release or baseline:
  Pester service-model assurance packet `v0.1.0`
- Owner:
  `#2069` with retained fork basis on `#2078`
- Scope:
  Trusted routing, context receipts, selection receipts, readiness receipts,
  execution-only behavior, and evidence classification for the Pester service
  model

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
| `Invoke-PesterExecutionPostprocess.ps1` execution-post contract | Execution | High | Verifies XML integrity classification and machine-readable summary repair occur after dispatch |
| `Run-PesterExecutionOnly.Local.ps1` local harness | Execution | High | Mirrors lock, LV guard, fixture prep, dispatcher profile, dispatch, execution-post, and local execution receipt without the workflow shell |

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

## Coverage Targets

| Metric | Target | Evidence |
| --- | --- | --- |
| Workflow contract coverage | All layer responsibilities represented | `tools/priority/__tests__/pester-service-model-workflow-contract.test.mjs` |
| Local harness contract coverage | Local execution slice stays aligned with workflow execution boundaries | `tools/priority/__tests__/pester-service-model-local-harness-contract.test.mjs` |
| Receipt coverage | Context, selection, readiness, execution, and evidence all emit auditable artifacts | assurance report + integration runs |
| Classification coverage | blocked and defect outcomes remain distinguishable | evidence workflow outputs |
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
