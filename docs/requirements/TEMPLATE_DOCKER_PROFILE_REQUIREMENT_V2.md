# Template Docker Profile Requirement V2

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
| Generated repository | A repository rendered from the template |

## Definitions

| Term | Definition |
| --- | --- |
| `hosted` | A render that does not include the Docker deployment profile |
| `docker` | A render that includes the Docker deployment profile |
| `mixed` | A render that includes both the hosted and Docker deployment surfaces |
| fail closed | Stop the relevant workflow before Docker-backed proving, return a failing status, and do not substitute or relax missing prerequisites |
| heavy runtime/governor implementation | Queue, governor, release/publication, and other runtime-control implementations owned by `compare-vi-cli-action` |
| authoritative image contract | The producer-published source that defines the allowed image reference for the Docker profile |

## Assumptions And Dependencies

- `compare-vi-cli-action` remains the upstream producer for capability and
  image contracts.
- The generated repository consumes upstream contracts rather than vendoring
  queue/governor/release behavior.
- TestStand remains a Windows-only execution surface.
- Windows-native LabVIEW x32/x64 parity remains outside the Docker profile.

## Requirements

### Group 1: Profile Selection

- `TDPR-001` `LabviewGitHubCiTemplate` shall expose a cookiecutter input named
  `execution_profile`.
- `TDPR-002` The supported values of `execution_profile` shall be `hosted`,
  `docker`, and `mixed`.
- `TDPR-003` The `docker` and `mixed` values shall be opt-in.
- `TDPR-004` The template shall not render Docker-profile artifacts unless
  `execution_profile` is explicitly set to `docker` or `mixed`.

### Group 2: Docker Artifact Contract

- `TDPR-005` When `execution_profile=docker`, the template shall render
  `.github/comparevi/capabilities.json`.
- `TDPR-006` When `execution_profile=docker`, the template shall render
  `.github/comparevi/lineage.json`.
- `TDPR-007` When `execution_profile=docker`, the template shall render:
  - a Docker capability manifest
  - a Docker lane policy
  - one or more Docker workflow scaffolds
  - consumer documentation for Docker execution
- `TDPR-008` When `execution_profile=mixed`, the template shall render all
  artifacts required by `TDPR-005` through `TDPR-007`.
- `TDPR-009` When `execution_profile=mixed`, the template shall also retain the
  non-Docker consumer surface produced by the `hosted` profile.

### Group 3: Portable Descendant Contract Surface

- `TDPR-010` The Docker-profile render shall include descendant-facing contract
  surfaces for:
  - treasury policy
  - ingress runner routing
  - execution and lane policy
  - handoff and live-state entrypoints
- `TDPR-011` The descendant-facing contract surfaces shall be limited to
  consumer-facing policy, manifest, and entrypoint surfaces.
- `TDPR-012` The Docker-profile render shall not include the full internal
  runtime stack from `compare-vi-cli-action`.

### Group 4: Image Contract

- `TDPR-013` A generated repository rendered with `execution_profile=docker` or
  `mixed` shall consume a pinned upstream image reference.
- `TDPR-014` The pinned upstream image reference shall be either:
  - digest-pinned
  - version-pinned in the authoritative image contract published by
    `compare-vi-cli-action`
- `TDPR-015` If the authoritative image reference is missing, malformed, or
  inconsistent with the selected Docker profile, the Docker workflow shall fail
  closed.

### Group 5: Isolation And Host Coexistence

- `TDPR-016` The Docker profile shall define a namespaced identity scheme for:
  - project or compose name
  - container names
  - network names
  - volume names
  - result and artifact paths
- `TDPR-017` The namespaced identity scheme shall permit multiple repositories
  or lanes to share a host Docker engine without name collision or result-path
  overwrite under the supported execution model.
- `TDPR-018` A generated repository rendered with the Docker profile shall not
  require exclusive ownership of the host Docker engine.

### Group 6: Platform Boundary

- `TDPR-019` The Docker profile shall not execute TestStand workloads.
- `TDPR-020` TestStand workloads shall remain a Windows-only execution surface.
- `TDPR-021` The Docker profile shall not replace Windows-native LabVIEW
  x32/x64 parity execution.
- `TDPR-022` Windows-native LabVIEW x32/x64 parity execution shall remain
  outside the Docker profile as a separate execution profile or workload class.

### Group 7: Producer / Distributor Boundary

- `TDPR-023` `compare-vi-cli-action` shall remain the source of:
  - authoritative capability contracts
  - authoritative image contracts
  - heavy runtime behavior
  - governor behavior
  - release and publication logic
- `TDPR-024` `LabviewGitHubCiTemplate` shall remain limited to:
  - distribution
  - cookiecutter stamping
  - lightweight consumer scaffolds
  - descendant-facing policy, manifest, and documentation surfaces needed to
    consume upstream contracts
- `TDPR-025` A generated repository rendered from the template shall consume
  the pinned upstream release surface and shall not vendor the queue, governor,
  or release/publication implementation from `compare-vi-cli-action`.

### Group 8: Rendered Consumer Verification

- `TDPR-026` Template self-validation shall render at least one non-Docker
  consumer.
- `TDPR-027` Template self-validation shall render at least one Docker-profile
  consumer.
- `TDPR-028` Template self-validation shall verify that the Docker-profile
  render contains all artifacts required by `TDPR-005` through `TDPR-010`.
- `TDPR-029` Template self-validation shall verify that the Docker-profile
  render excludes the implementations prohibited by `TDPR-012` and `TDPR-025`.
- `TDPR-030` Template self-validation shall verify that the Docker workflow
  fails closed when:
  - Docker is unavailable
  - the image pin is missing
  - the engine or context does not satisfy Docker-profile preconditions
- `TDPR-031` The Docker-profile render shall coexist with the existing
  `vi-history` distributor contract without removing or overwriting required
  `vi-history` surfaces.

## Verification Mapping

| Group | Methods |
| --- | --- |
| Profile Selection | Inspection, test |
| Docker Artifact Contract | Inspection, test |
| Portable Descendant Contract Surface | Inspection |
| Image Contract | Inspection, demonstration, test |
| Isolation And Host Coexistence | Inspection, test |
| Platform Boundary | Inspection, analysis, test |
| Producer / Distributor Boundary | Inspection |
| Rendered Consumer Verification | Test |

## Constraint Notes

- The template does not become the owner of the heavy orchestration stack from
  `compare-vi-cli-action`.
- The Docker profile does not replace Windows-native or TestStand execution
  lanes.
