# Template Docker Profile Implementation Backlog V1

## Purpose

This backlog turns the approved baseline requirement
`baseline-template-docker-profile-requirement-v1` into an implementation
sequence that can be executed across:

- `compare-vi-cli-action` as Producer
- `LabviewGitHubCiTemplate` as distributor

The implementation target is the approved requirement baseline:

- requirement baseline tag: `baseline-template-docker-profile-requirement-v1`
- requirement source:
  [TEMPLATE_DOCKER_PROFILE_REQUIREMENT_V9.md](/C:/dev/compare-vi-cli-action/compare-vi-cli-action/docs/requirements/TEMPLATE_DOCKER_PROFILE_REQUIREMENT_V9.md)

## Outcome

When this backlog is complete, `LabviewGitHubCiTemplate` should be able to
render a governed Docker-capable consumer profile that:

- supports `execution_profile = hosted | docker | mixed`
- consumes Producer-published contract surfaces rather than vendoring compare
  internals
- stamps portable governance surfaces into generated consumers
- proves `hosted`, `docker`, and `mixed` renders in template self-validation
- preserves the existing `vi-history` distributor contract

## Current Gap Summary

The approved requirement baseline expects template-distributed surfaces that do
not yet exist together as one implementation set:

- cookiecutter profile selection for `docker` and `mixed`
- Docker capability-manifest content
- Docker workflow and policy surfaces
- portable descendant governance surfaces
- self-validation for `docker` and `mixed`
- Producer-side authoritative image-contract publication for the template to
  consume

## Delivery Order

### Slice 0: Producer Contract Prerequisite

- ID: `TDP-IMP-00`
- Owner repo: `compare-vi-cli-action`
- Goal:
  - publish the Producer-side contract surface that the template Docker profile
    will consume
- Deliverables:
  - authoritative image-contract source in a Producer-published contract
  - documented contract path and pin semantics
  - release-facing proof that the template can resolve the contract from the
    published Producer surface
- Depends on:
  - current CompareVI producer publication rail
- Exit criteria:
  - a template consumer can resolve the image contract from a Producer-owned,
    immutable published surface

### Slice 1: Template Profile Selection

- ID: `TDP-IMP-01`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - add `execution_profile` selection to cookiecutter
- Deliverables:
  - cookiecutter input `execution_profile`
  - supported values:
    - `hosted`
    - `docker`
    - `mixed`
  - default behavior remains non-Docker
- Depends on:
  - none
- Exit criteria:
  - template render selects `hosted`, `docker`, or `mixed`
  - Docker-profile outputs do not appear in `hosted`

### Slice 2: Docker Capability Manifest

- ID: `TDP-IMP-02`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - extend the rendered capability manifest so Docker consumers can resolve
    Producer-published image contracts
- Deliverables:
  - `.github/comparevi/capabilities.json` content for Docker profile
  - authoritative image-contract source field
  - profile-aware capability metadata
- Depends on:
  - `TDP-IMP-00`
  - `TDP-IMP-01`
- Exit criteria:
  - Docker and mixed renders carry the required capability-manifest content
  - hosted renders remain free of Docker-specific capability requirements

### Slice 3: Docker Workflow And Documentation Set

- ID: `TDP-IMP-03`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - stamp the Docker workflow/documentation set into rendered consumers
- Deliverables:
  - Docker lane policy
  - one or more Docker workflow scaffolds
  - Docker execution documentation for consumers
- Depends on:
  - `TDP-IMP-01`
  - `TDP-IMP-02`
- Exit criteria:
  - Docker render emits the expected policy, workflow, and docs
  - mixed render retains hosted consumer surfaces while also emitting Docker
    surfaces

### Slice 4: Portable Governance Pack

- ID: `TDP-IMP-04`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - stamp the descendant-facing governance pack without copying compare's heavy
    runtime implementation
- Deliverables:
  - treasury policy surface
  - ingress runner routing surface
  - execution and lane policy surface
  - handoff entrypoints
  - live-state entrypoints
- Depends on:
  - `TDP-IMP-01`
  - `TDP-IMP-02`
- Exit criteria:
  - generated consumers carry the portable governance pack
  - generated consumers do not vendor Producer implementation content

### Slice 5: Boundary Guard And Exclusion Verification

- ID: `TDP-IMP-05`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - prove the distributor boundary is respected in rendered outputs
- Deliverables:
  - checks or fixtures that reject Producer implementation content in generated
    consumers
  - checks that validate consumer-facing outputs only
- Depends on:
  - `TDP-IMP-03`
  - `TDP-IMP-04`
- Exit criteria:
  - template self-validation can prove generated consumers exclude Producer
    implementation content

### Slice 6: Render Matrix Self-Validation

- ID: `TDP-IMP-06`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - prove the full render matrix required by the baseline
- Deliverables:
  - self-validation for:
    - `hosted`
    - `docker`
    - `mixed`
  - checks for:
    - Docker fail-closed behavior
    - `vi-history` surface preservation
    - Docker and mixed output completeness
- Depends on:
  - `TDP-IMP-03`
  - `TDP-IMP-04`
  - `TDP-IMP-05`
- Exit criteria:
  - template self-validation proves `hosted`, `docker`, and `mixed`
  - `vi-history` required surfaces remain present in Docker-profile renders

### Slice 7: Producer-Native Pin Promotion

- ID: `TDP-IMP-07`
- Owner repo: `LabviewGitHubCiTemplate`
- Goal:
  - promote the template from the older `vi-history` pin to the current
    Producer-native contract once the Producer publication is authoritative
- Deliverables:
  - updated consumer pin defaults
  - updated rendered docs/examples
  - updated self-validation fixtures
- Depends on:
  - `TDP-IMP-00`
  - `TDP-IMP-06`
- Exit criteria:
  - template defaults point at the authoritative Producer-native contract
  - self-validation proves the promoted pin

## Recommended Landing Sequence

1. `TDP-IMP-00`
2. `TDP-IMP-01`
3. `TDP-IMP-02`
4. `TDP-IMP-03`
5. `TDP-IMP-04`
6. `TDP-IMP-05`
7. `TDP-IMP-06`
8. `TDP-IMP-07`

## First Work Rail

If we start immediately, the first concrete rail I would open is:

- `TDP-IMP-01` + `TDP-IMP-02`

Reason:

- they establish the profile-selection and manifest contract foundation
- they are the smallest template-side slices that unblock every later Docker
  profile surface
- they do not require the whole governance pack to land first

## Done Definition

This backlog is complete when:

- the baseline requirement is fully implemented in `LabviewGitHubCiTemplate`
- template self-validation proves `hosted`, `docker`, and `mixed`
- generated consumers carry portable governance surfaces only
- generated consumers do not vendor Producer implementation content
- Docker-profile renders preserve the required `vi-history` surfaces
- the template defaults point at an authoritative Producer-native contract
