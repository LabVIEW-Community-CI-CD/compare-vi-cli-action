# Template Docker Profile Requirement V6

## Purpose

This requirement set defines the Docker deployment profile contract for
`LabviewGitHubCiTemplate`.

The intent is to let the template distribute a governed Docker-capable consumer
profile without transferring ownership of the heavy compare platform runtime
from `compare-vi-cli-action`.

## Subject Entities

| Term | Meaning |
| --- | --- |
| Template | `LabviewGitHubCiTemplate` |
| Producer | `compare-vi-cli-action` |
| Generated repository | A repository rendered from the Template |

## Definitions And Reference Bindings

| Term | Definition |
| --- | --- |
| `hosted` | A render that does not include the Docker deployment profile |
| `docker` | A render that includes the Docker deployment profile |
| `mixed` | A render that includes both the hosted and Docker deployment surfaces |
| fail closed | Stop the relevant workflow before Docker-backed proving, return a failing status, and do not substitute, infer, or relax missing prerequisites |
| hosted consumer surface | The non-Docker files, workflows, and configuration emitted by a `hosted` render |
| Docker capability manifest | The rendered file `.github/comparevi/capabilities.json` when `execution_profile` is `docker` or `mixed` |
| Docker workflow/documentation set | The Docker lane policy, one or more Docker workflow scaffolds, and consumer documentation for Docker execution |
| descendant contract surface set | Treasury policy, ingress runner routing, execution and lane policy, handoff entrypoints, and live-state entrypoints |
| namespaced identity scheme | The naming and path rules for project or compose name, container names, network names, volume names, result paths, and artifact paths |
| Producer-owned runtime set | The Producer-owned capability contracts, image contracts, heavy runtime behavior, governor behavior, and release/publication logic |
| supported execution model | One host Docker engine may be shared concurrently by multiple repositories or lanes when the namespaced identity scheme is applied |
| required `vi-history` surfaces | `.github/comparevi/capabilities.json`, `.github/comparevi/lineage.json`, `.github/workflows/vi-history.yml`, and `docs/VI_HISTORY_CAPABILITY.md` |
| pinned upstream release surface | The Producer-published `CompareVI.Tools` release bundle and embedded `comparevi-tools-release.json` payload identified by `versionContract.authoritativeConsumerPin` and the referenced capability `contractPaths` |
| authoritative image contract source | The value recorded in the Docker capability manifest that identifies the Producer-published image contract artifact by immutable producer release pin and contract path |
| Docker-profile preconditions | Docker is available, the selected engine/context satisfies the Docker profile, and the required upstream image reference is present and valid |
| Docker-profile render | A render produced when `execution_profile` is `docker` or `mixed` |
| preserve | Keep present at the required repository path in the rendered repository |

## Assumptions And Dependencies

### Assumptions

| ID | Assumption |
| --- | --- |
| `A1` | The Producer continues to publish `CompareVI.Tools` and embedded `comparevi-tools-release.json` metadata with `versionContract.authoritativeConsumerPin` and capability `contractPaths` |
| `A2` | The Producer-published image contract artifact remains available through the authoritative image contract source |
| `A3` | Template self-validation can render `hosted`, `docker`, and `mixed` consumers in the review baseline |

### Dependencies

| ID | Dependency |
| --- | --- |
| `D1` | Group 4: Image Contract depends on the authoritative image contract source published by the Producer |
| `D2` | Group 5: Isolation And Host Coexistence depends on the supported execution model |
| `D3` | Group 7: Producer / Distributor Boundary depends on the pinned upstream release surface published by the Producer |
| `D4` | Group 8: Rendered Consumer Verification depends on the template self-validation matrix covering `hosted`, `docker`, and `mixed` renders |

## Requirements

### Group 1: Profile Selection

- `TDPR-001` The Template shall expose a cookiecutter input named
  `execution_profile`.
- `TDPR-002` The supported values of `execution_profile` shall be `hosted`,
  `docker`, and `mixed`.
- `TDPR-003` The `docker` and `mixed` values shall be opt-in selections.
- `TDPR-004` The Template shall render the outputs required by `TDPR-005`,
  `TDPR-005A`, `TDPR-006`, `TDPR-007`, and `TDPR-010` only when
  `execution_profile` is `docker` or `mixed`.

### Group 2: Docker Artifact Contract

- `TDPR-005` When `execution_profile=docker`, the Template shall render
  `.github/comparevi/capabilities.json`.
- `TDPR-005A` When `execution_profile=docker`, the Template shall render a
  Docker capability manifest containing the authoritative image contract
  source.
- `TDPR-006` When `execution_profile=docker`, the Template shall render
  `.github/comparevi/lineage.json`.
- `TDPR-007` When `execution_profile=docker`, the Template shall render the
  Docker workflow/documentation set.
- `TDPR-008` When `execution_profile=mixed`, the Template shall satisfy
  `TDPR-005`, `TDPR-005A`, `TDPR-006`, and `TDPR-007`.
- `TDPR-009` When `execution_profile=mixed`, the Template shall retain the
  hosted consumer surface.

### Group 3: Portable Descendant Contract Surface

- `TDPR-010` The Docker-profile render shall include the descendant contract
  surface set.
- `TDPR-011` The Docker-profile render shall limit descendant-facing contract
  content to consumer-facing policy, manifest, entrypoint, and documentation
  surfaces.
- `TDPR-012` The Docker-profile render shall not include the full internal
  runtime stack from the Producer-owned runtime set.

### Group 4: Image Contract

- `TDPR-013` A Generated repository rendered with `execution_profile=docker` or
  `mixed` shall resolve its upstream image reference from the Producer-published
  image contract identified by the authoritative image contract source recorded
  in the Docker capability manifest.
- `TDPR-014` The upstream image reference shall be either:
  - digest-pinned
  - version-pinned in the authoritative image contract published by the
    Producer
- `TDPR-015` When any Docker-profile precondition is unsatisfied, the
  Docker-profile validation workflow shall fail closed.

### Group 5: Isolation And Host Coexistence

- `TDPR-016` The Docker profile shall define the namespaced identity scheme.
- `TDPR-017` Under the supported execution model, the namespaced identity
  scheme shall prevent name collision and result-path overwrite when multiple
  repositories or lanes share a host Docker engine.
- `TDPR-018` A Generated repository rendered with the Docker profile shall not
  require exclusive ownership of the host Docker engine.

### Group 6: Platform Boundary

- `TDPR-019` The Docker profile shall not execute TestStand workloads.
- `TDPR-020` TestStand workloads shall remain a Windows-only execution
  surface.
- `TDPR-021` The Docker profile shall not replace Windows-native LabVIEW
  x32/x64 parity execution.
- `TDPR-022` Windows-native LabVIEW x32/x64 parity execution shall remain a
  separate execution profile or workload class outside the Docker profile.

### Group 7: Producer / Distributor Boundary

- `TDPR-023` The Producer shall remain the source of the Producer-owned runtime
  set.
- `TDPR-024` The Template shall remain limited to distribution, cookiecutter
  stamping, lightweight consumer scaffolds, and descendant-facing policy,
  manifest, entrypoint, and documentation surfaces needed to consume upstream
  contracts.
- `TDPR-025` A Generated repository rendered from the Template shall consume
  the pinned upstream release surface identified by
  `versionContract.authoritativeConsumerPin` and the referenced capability
  `contractPaths`.
- `TDPR-025A` A Generated repository rendered from the Template shall not
  vendor the Producer-owned runtime set.

### Group 8: Rendered Consumer Verification

- `TDPR-026` Template self-validation shall render at least one `hosted`
  consumer.
- `TDPR-027` Template self-validation shall render at least one `docker`
  consumer.
- `TDPR-027A` Template self-validation shall render at least one `mixed`
  consumer.
- `TDPR-028` Template self-validation shall verify that each `docker` render
  satisfies `TDPR-005`, `TDPR-005A`, `TDPR-006`, `TDPR-007`, and `TDPR-010`.
- `TDPR-028A` Template self-validation shall verify that each `mixed` render
  satisfies `TDPR-005`, `TDPR-005A`, `TDPR-006`, `TDPR-007`, `TDPR-009`, and
  `TDPR-010`.
- `TDPR-029` Template self-validation shall verify that `docker` and `mixed`
  renders exclude the content prohibited by `TDPR-012` and `TDPR-025A`.
- `TDPR-030` Template self-validation shall verify fail-closed behavior for
  each Docker-profile precondition.
- `TDPR-031` Each Docker-profile render shall keep the required `vi-history`
  surfaces present at their required repository paths.
- `TDPR-031A` Template self-validation shall verify that at least one `docker`
  render and at least one `mixed` render satisfy `TDPR-031`.

## Verification Mapping

| Group | Methods |
| --- | --- |
| Profile Selection | Inspection, test |
| Docker Artifact Contract | Inspection, test |
| Portable Descendant Contract Surface | Inspection |
| Image Contract | Inspection, analysis, test |
| Isolation And Host Coexistence | Inspection, demonstration, test |
| Platform Boundary | Inspection, analysis |
| Producer / Distributor Boundary | Inspection, analysis |
| Rendered Consumer Verification | Test |

## References

- `CrossRepo-VIHistory` — `docs/knowledgebase/CrossRepo-VIHistory.md`
- `CompareVI.Tools Release Manifest v1 schema` —
  `docs/schemas/comparevi-tools-release-manifest-v1.schema.json`
- `CompareVI.Tools VI History Capability v1 schema` —
  `docs/schemas/comparevi-tools-vi-history-capability-v1.schema.json`

## Constraint Notes

- The Template does not become the owner of the heavy orchestration stack from
  `compare-vi-cli-action`.
- The Docker profile does not replace Windows-native or TestStand execution
  lanes.
