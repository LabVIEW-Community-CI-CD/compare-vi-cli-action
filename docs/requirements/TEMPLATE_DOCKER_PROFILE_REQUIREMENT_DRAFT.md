# Template Docker Profile Requirement Draft

## Purpose

This draft captures the current requirement for extending
`LabviewGitHubCiTemplate` so it can distribute a governed Docker deployment
profile through cookiecutter while preserving the existing producer/distributor
boundary with `compare-vi-cli-action`.

This file is intended for external review and refinement. A reviewed revision
can replace or supersede this draft in a later V2 update.

## Canonical Requirement

`LabviewGitHubCiTemplate` shall support a cookiecutter-selectable Docker
deployment profile that generates a governed autonomous LabVIEW delivery node
with portable container-lane contracts, while preserving the existing boundary
that `compare-vi-cli-action` remains the upstream platform producer and the
template remains the distributor.

## Expanded Requirement

### 1. Profile Selection

- The template shall expose a cookiecutter input for execution profile
  selection.
- The minimum supported values shall be:
  - `hosted`
  - `docker`
  - `mixed`
- The `docker` and `mixed` profiles shall be opt-in.

### 2. Governed Docker Profile

- When the Docker profile is selected, the template shall generate:
  - a Docker capability manifest
  - a Docker lane policy
  - workflow scaffolds for Docker-backed proving
  - consumer documentation for Docker execution
  - lineage and capability metadata tied to `compare-vi-cli-action` as the
    upstream producer

### 3. Portable Minimum Bar

- The generated Docker profile shall include portable governed surfaces for:
  - treasury policy
  - ingress runner routing contract
  - execution and lane policy
  - handoff and live-state entrypoints
- These surfaces shall remain lightweight descendant contracts and shall not
  copy the full internal runtime stack from `compare-vi-cli-action`.

### 4. Image Contract

- Docker-backed generated repositories shall consume pinned image references.
- Image references shall be versioned or digest-pinned.
- The generated Docker profile shall fail closed on missing or mismatched image
  contracts.

### 5. Isolation Contract

- The Docker profile shall define namespaced lane identity for:
  - project or compose name
  - containers
  - networks
  - volumes
  - results and artifact paths
- The generated repository shall not assume exclusive ownership of the host
  Docker engine.

### 6. Platform Boundary

- Docker profile support shall not collapse Windows-native or TestStand-backed
  work into containers.
- TestStand shall remain a Windows-only execution surface.
- Native LabVIEW x32 and x64 parity shall remain a separate execution profile
  or workload class.

### 7. Producer/Distributor Boundary

- `compare-vi-cli-action` shall remain the owner of:
  - heavy runtime and governor behavior
  - release and publication logic
  - authoritative capability and image contracts
- `LabviewGitHubCiTemplate` shall remain the owner of:
  - distribution
  - cookiecutter stamping
  - lightweight consumer scaffolds
  - descendant-facing policy, manifests, and documentation

### 8. Rendered Consumer Verification

- Template self-validation shall render at least:
  - a non-Docker consumer
  - a Docker-profile consumer
- Validation shall prove that the generated repository contains the expected
  governed surfaces and Docker profile contracts.

## Acceptance Criteria

- A cookiecutter render with `execution_profile=docker` produces:
  - `.github/comparevi/capabilities.json`
  - `.github/comparevi/lineage.json`
  - Docker profile policy and manifest files
  - Docker workflow scaffolds
  - consumer documentation
- The generated Docker workflow fails closed when:
  - Docker is unavailable
  - the image pin is missing
  - the engine or context is wrong
- The generated repository does not include the full queue or governor
  implementation from `compare-vi-cli-action`.
- The template's own smoke workflow verifies both the standard render and the
  Docker-profile render.
- The Docker profile coexists with the existing `vi-history` distributor
  contract.

## Non-Goals

- The template shall not become the owner of the heavy orchestration stack from
  `compare-vi-cli-action`.
- The template shall not assume Docker replaces Windows-native or TestStand
  execution lanes.

## Review Note

This draft is intentionally written as a functional requirement seed rather
than a final ISO 29148-compliant requirement set. A reviewed V2 can tighten the
language, split compound statements, and add verification method assignments as
needed.
