# Pester Service Model Information Item Map

## Scope

- Product or service:
  Pester service-model control plane
- Repository:
  `compare-vi-cli-action`
- Baseline:
  Upstream pilot program `#2069` using the retained fork dossier from `#2078`
- Owner:
  Engineering

## Information Items

| Item Type | Current Path | Owner | Trigger | Proving Evidence |
| --- | --- | --- | --- | --- |
| Plan | `docs/testing/pester-service-model-test-plan.md` | Engineering | Layer or receipt change | Workflow-contract and hosted release-evidence gates stay aligned |
| Specification | `docs/requirements-pester-service-model-srs.md` | Engineering | Contract change | REQ IDs remain linked to tests and workflow/code refs |
| Report | `docs/pester-service-model-quality-report.md` | Engineering | Assurance rerun | Report links to current assurance outputs |
| Procedure | `docs/release-procedure-pester-service-model.md` | Engineering | Mount or promotion decision | Procedure matches the additive promotion flow |
| Architecture | `docs/architecture/pester-service-model-control-plane.md` | Engineering | Layer boundary change | Architecture packet and ADR remain current |
| Traceability | `docs/rtm-pester-service-model.csv` | Engineering | Requirement or verification change | RTM remains current |

## Notes

- The service model is a subsystem within the repo, not merely a collection of workflows.
- The retained fork packet exists to justify the first upstream promotion
  slices; hosted packet evidence then carries the upstream line forward.
