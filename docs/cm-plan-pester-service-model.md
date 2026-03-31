# Pester Service Model Configuration Management Plan

## Scope

- Product or service:
  Pester service-model control plane
- Managed baselines:
  upstream issue `#2069`, the retained fork dossier for `#2078`, and any
  intentional `integration/**` mounts used to prove the subsystem

## Configuration Items

| CI | Type | Owner | Baseline Rule |
| --- | --- | --- | --- |
| Service-model workflows | Code | Engineering | Versioned on branch baselines and mounted upstream intentionally |
| Workflow-contract tests | Test artifact | Engineering | Must track the declared layer responsibilities |
| Requirement and promotion packet | Document set | Engineering | Versioned with the promoted upstream slice and linked back to the retained fork dossier |
| Execution and evidence receipts | Artifact | Engineering | Retained as proof for service-model decisions |

## Versioning

- Scheme: `v0.1.0` for the service-model assurance packet
- Tag trigger:
  A pilot baseline may be tagged when the additive model is stable enough to
  compare directly against the monolith
- Release branch rule:
  Promotion to upstream or release branches occurs only after explicit proof on
  the integration rail

## Change Control

| Change Type | Approval | Timing |
| --- | --- | --- |
| Standard | Branch review plus issue log on `#2069` or `#2078` | Before push or mount |
| Urgent | Maintainer approval | Same day |
| Concession | Recorded in the issue ledger with rationale | Before merge or promotion |

## Status Accounting

- Record location:
  `#2069`, the retained fork dossier for `#2078`, integration proof runs, and
  the hosted release-evidence bundles
- Release record owner:
  Pester service-model pilot program
- Audit trail:
  Git history, integration proof runs, retained release-evidence bundles, and
  the retained fork promotion dossier

## Baseline And Release Evidence

- Baseline decisions must reference a concrete branch or integration rail state.
- Release flow evidence is anchored by `.github/workflows/release.yml`.
- Packet-level retained evidence is anchored by
  `.github/workflows/pester-service-model-release-evidence.yml`.
- The packet release bundle retains `coverage.xml`, `docs-link-check.json`, the
  RTM, the quality report, and the generated promotion dossier.
- Promotion remains additive until the service model proves equivalent or better
  behavior than the monolith.
