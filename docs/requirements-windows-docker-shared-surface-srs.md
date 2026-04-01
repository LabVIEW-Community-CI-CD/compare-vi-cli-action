# Windows Docker Shared Surface SRS

## Document Control

- System: Windows Docker shared local proof surface
- Version: `v0.2.1`
- Owner: `#2069`
- Status: Active

## Scope

- Purpose:
  Specify the shared Windows Docker Desktop + pinned NI Windows image proof
  surface that adjacent packets should use before another hosted rerun is
  chosen.
- In scope:
  Bounded readiness probes, deterministic host bootstrap and preflight,
  OneDrive-safe local path hygiene, local assurance CI, and shared local proof
  program integration.
- Out of scope:
  Product-layer Pester execution, VI History replay semantics, and hosted trust
  routing.

## Stakeholders

| Role | Need | Priority |
| --- | --- | --- |
| Product | Avoid spending GitHub CI on defects that should be found on the shared Windows surface first | High |
| Engineering | Use one explicit Windows Docker Desktop + NI image packet across Pester and VI History instead of duplicating surface logic | High |
| QA | Trace shared-surface readiness, path hygiene, and escalation contracts to requirements and tests | High |
| Operations | Keep Windows Docker host preparation bounded, machine-readable, and safe from synced-root hazards | High |

## Requirements

| ID | Requirement | Rationale | Fit Criterion | Verification |
| --- | --- | --- | --- | --- |
| REQ-WDSS-001 | A stable shared-surface readiness probe shall exist for Docker Desktop Windows engine plus the pinned NI Windows image, and it shall emit a machine-readable receipt with explicit readiness and host-unavailable states. | The cheapest truthful next proof often depends on knowing whether the shared Windows Docker surface is actually ready before any packet tries to use it. | `Invoke-PesterWindowsContainerSurfaceProbe.ps1` emits `pester-windows-container-surface.json` with bounded statuses such as `ready`, `not-windows-host`, `docker-cli-missing`, `docker-engine-not-windows`, and `ni-image-missing`. | `TEST-WDSS-001` |
| REQ-WDSS-002 | A deterministic Windows host bootstrap and preflight contract shall exist for the pinned NI image surface, separate from packet-specific execution. | Shared infrastructure should be certified once and then reused by adjacent proof packets instead of each packet improvising its own host preparation. | `Test-WindowsNI2026q1HostPreflight.ps1` emits `comparevi/windows-host-preflight@v1`, and the packet documents the bounded bootstrap plus probe command order. | `TEST-WDSS-002` |
| REQ-WDSS-003 | The shared Windows proof packet shall detect unsafe synchronized or externally managed local roots, such as OneDrive-managed paths, before it recommends live Windows proof work. | Synced roots can introduce background file mutation and non-deterministic behavior during local container proof, so path hygiene must be explicit instead of assumed. | Local CI emits `windows-docker-shared-surface-path-hygiene.json`, records repo and results-root risk assessment, and emits a machine-readable relocation escalation when a managed root is detected. | `TEST-WDSS-003` |
| REQ-WDSS-004 | Local assurance CI shall synthesize the shared Windows surface packet into a machine-readable report, ranked backlog, proof checks, and next step for local-first development. | The shared surface should govern itself explicitly instead of existing only as a merged advisory produced by sibling packets. | A dedicated Windows shared-surface local CI entrypoint emits a report, summary, and next-step artifact grounded in the packet, code refs, and proof checks. | `TEST-WDSS-004` |
| REQ-WDSS-005 | When the next truthful shared-surface proof is unavailable from the current host, local assurance CI shall emit a machine-readable escalation to `windows-docker-desktop-ni-image` with exact next commands. | Autonomous development needs a bounded handoff packet instead of a prose-only note when the current host cannot satisfy the shared Windows surface. | When the probe or host state prevents live proof, local CI emits `windows-docker-shared-surface-next-step.json` naming the blocked requirement, governing requirement, required surface, host state, receipt path, and recommended commands. | `TEST-WDSS-005` |
| REQ-WDSS-006 | The shared Windows surface packet shall participate in the shared local proof program selector so it can be chosen explicitly beside Pester and VI History. | Once the Windows surface becomes a first-class packet, the autonomy loop should be able to reason about it directly rather than only through merged packet advisories. | `priority:program:local-ci` consumes the shared-surface next-step artifact, can select a shared-surface requirement ahead of sibling packet escalations, and merges common `windows-docker-desktop-ni-image` handoffs across all packets. | `TEST-WDSS-006` |
| REQ-WDSS-007 | When a reachable Windows host bridge exists behind a Unix or WSL coordinator, the shared Windows surface packet shall use that governed bridge to execute Windows-local probe and preflight work before emitting a host-unavailable escalation. | A WSL-based operator should not stop at a human handoff if the actual Windows Docker Desktop + NI image surface is already reachable from the same session. | `windows-host-bridge.mjs` resolves the reachable Windows PowerShell and Node surfaces, the shared-surface local CI uses that bridge to run `Invoke-PesterWindowsContainerSurfaceProbe.ps1` and `Test-WindowsNI2026q1HostPreflight.ps1`, and host-unavailable escalation is only emitted when that bridge is absent or the Windows surface still reports non-ready. | `TEST-WDSS-007` |
| REQ-WDSS-008 | When the coordinator is running from a UNC-backed WSL or other non-bindable Windows path, the shared Windows Docker surface shall stage container-bound inputs and output targets into a governed Windows-local mount root and synchronize artifacts back to the requested repo paths. | Windows Docker bind mounts do not reliably accept UNC-backed WSL paths, so local proof needs an explicit staging contract instead of rediscovering mount-spec failures at runtime. | `Run-NIWindowsContainerCompare.ps1` detects UNC-backed container-bound inputs or report paths, emits staging metadata in `ni-windows-container-capture.json`, uses a Windows-local stage root for Docker bind mounts, synchronizes report artifacts back to the requested repo paths, and records cleanup status. | `TEST-WDSS-008` |
