# Windows Docker Shared Surface

The shared Windows Docker Desktop + pinned NI Windows image surface should be
treated as its own local proof packet, not as an incidental advisory merged
from sibling packets.

## Local Proof Surfaces

- `tests:windows-surface:probe`
  - bounded readiness probe for Docker Desktop Windows engine and the pinned NI
    image
- `docker:ni:windows:bootstrap`
  - deterministic Windows host bootstrap and preflight
- `compare:docker:ni:windows:probe`
  - bounded container compare probe on the shared Windows surface
- `priority:windows-surface:local-ci`
  - machine-readable local assurance loop for the shared Windows surface

## Design Rules

- The shared Windows surface should govern itself explicitly instead of being
  inferred only through Pester or VI History packet advisories.
- Shared-surface path hygiene should be checked before live Windows proof is
  recommended. OneDrive-like managed roots are risk until a safe local root is
  used.
- Bootstrap, probe, and packet-local proof should remain separate contracts.
- The shared Windows surface should participate in the same local proof program
  selector as Pester and VI History.
- When the coordinator is running under WSL or another Unix host but a
  reachable Windows Desktop is available, the packet should bridge into that
  Windows host before emitting a `windows-docker-desktop-ni-image` escalation.
- Windows bridge invocations should use `ExecutionPolicy Bypass` for UNC-backed
  repo scripts and keep results under repo-local or other safe non-OneDrive
  roots.
- When Windows Docker cannot bind UNC-backed WSL paths directly, the compare
  surface should stage container-bound inputs and output targets into a
  Windows-local mount root, synchronize results back to the requested repo
  paths, and record the staging lifecycle in the capture artifact.

## Canonical Artifacts

- `pester-windows-container-surface.json`
- `comparevi/windows-host-preflight@v1`
- `windows-docker-shared-surface-path-hygiene.json`
- `windows-docker-shared-surface-local-ci-report.json`
- `windows-docker-shared-surface-next-step.json`
- `ni-windows-container-capture.json`

## Local Commands

- `npm run tests:windows-surface:probe`
- `npm run docker:ni:windows:bootstrap`
- `npm run compare:docker:ni:windows:probe`
- `npm run priority:windows-surface:local-ci`
- `npm run priority:windows-surface:next-step`
- `npm run priority:program:local-ci`
- `npm run priority:program:next-step`

## Shared Program Role

This packet is the authoritative home for the shared
`windows-docker-desktop-ni-image` surface. Pester and VI History may still
escalate to that surface, but the surface itself should also be governable as a
packet with its own requirements, proof checks, bounded next-step handoff, and
reachable Windows host bridge rules.
