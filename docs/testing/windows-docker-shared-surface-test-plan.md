# Windows Docker Shared Surface Test Plan

## Document Control

- System: Windows Docker shared local proof surface
- Version: `v0.2.3`
- Status: Active

## Verification Matrix

| Test ID | Coverage | Layer | Priority | Notes |
| --- | --- | --- | --- | --- |
| `TEST-WDSS-001` | Shared-surface readiness probe coverage | Probe/Receipt | High | Verifies the shared Windows readiness probe emits bounded readiness states and a machine-readable receipt |
| `TEST-WDSS-002` | Bootstrap and preflight contract coverage | Bootstrap/Host | High | Verifies the deterministic Windows host bootstrap/preflight commands remain explicit and stable |
| `TEST-WDSS-003` | Path-hygiene coverage | Safety/Local | High | Verifies the shared surface detects OneDrive-like managed roots and emits a relocation escalation |
| `TEST-WDSS-004` | Local assurance-loop coverage | Assurance/Contract | High | Verifies the shared-surface local CI emits a report, proof checks, and next-step artifact |
| `TEST-WDSS-005` | Host-unavailable escalation coverage | Assurance/Contract | High | Verifies local CI emits a machine-readable escalation to `windows-docker-desktop-ni-image` when the current host cannot satisfy the surface |
| `TEST-WDSS-006` | Shared local-program selector coverage | Assurance/Contract | High | Verifies the shared surface participates explicitly in the program selector beside Pester and VI History |
| `TEST-WDSS-007` | Reachable Windows host bridge coverage | Assurance/Contract | High | Verifies a Unix or WSL coordinator uses a reachable Windows host bridge for probe and preflight work before emitting host-unavailable escalation |
| `TEST-WDSS-008` | UNC-backed WSL staging coverage | Runtime/Windows Docker | High | Verifies UNC-backed WSL inputs and report paths are staged into a Windows-local mount root, synchronized back, and cleaned up after compare execution |
| `TEST-WDSS-009` | Authoritative CI gate coverage | Workflow/Contract | High | Verifies Windows image-backed CI gates route through the shared Windows NI proof workflow and not through the generic Pester reusable workflow |
| `TEST-WDSS-010` | Bounded timeout coverage | Runtime/Workflow | High | Verifies Windows preflight and runtime-manager Docker operations fail closed on timeout and the hosted preflight step carries an explicit workflow timeout |

## Entry Criteria

- The shared Windows surface packet docs and RTM stay in sync.
- The readiness probe, bootstrap/preflight scripts, and local CI entrypoint stay on disk at the declared paths.

## Exit Criteria

- Contract and local-CI tests covering the packet pass.
- The shared-surface local CI emits a machine-readable next step.
- On a non-Windows host with no reachable Windows bridge, the next step is an
  explicit escalation packet rather than prose-only guidance.

## Traceability Notes

| Coverage | Proof | Reference |
| --- | --- | --- |
| Shared-surface readiness probe coverage | `Invoke-PesterWindowsContainerSurfaceProbe.ps1` emits a bounded readiness receipt | `tests/Invoke-PesterWindowsContainerSurfaceProbe.Tests.ps1`, `tools/priority/__tests__/windows-docker-shared-surface-contract.test.mjs`, `TEST-WDSS-001` |
| Bootstrap and preflight contract coverage | The packet documents and preserves the deterministic bootstrap plus probe command order and underlying tools | `tools/priority/__tests__/windows-docker-shared-surface-contract.test.mjs`, `TEST-WDSS-002` |
| Path-hygiene coverage | Shared-surface local CI emits `windows-docker-shared-surface-path-hygiene.json` and a relocation escalation on OneDrive-like roots | `tools/priority/__tests__/windows-docker-shared-surface-local-ci.test.mjs`, `TEST-WDSS-003` |
| Local assurance-loop coverage | Shared-surface local CI emits report, summary, and next-step artifacts | `tools/priority/__tests__/windows-docker-shared-surface-local-ci.test.mjs`, `TEST-WDSS-004` |
| Host-unavailable escalation coverage | Shared-surface local CI emits an explicit `windows-docker-desktop-ni-image` handoff packet | `tools/priority/__tests__/windows-docker-shared-surface-local-ci.test.mjs`, `TEST-WDSS-005` |
| Shared local-program selector coverage | Program CI consumes the shared-surface next-step artifact beside Pester and VI History | `tools/priority/__tests__/comparevi-local-program-ci.test.mjs`, `tools/priority/__tests__/windows-docker-shared-surface-contract.test.mjs`, `TEST-WDSS-006` |
| Reachable Windows host bridge coverage | Shared-surface local CI can consume a reachable Windows host bridge from a Unix or WSL coordinator and only escalates when that bridge is absent or still non-ready | `tools/priority/__tests__/windows-host-bridge.test.mjs`, `tools/priority/__tests__/windows-docker-shared-surface-contract.test.mjs`, `TEST-WDSS-007` |
| UNC-backed WSL staging coverage | `Run-NIWindowsContainerCompare.ps1` stages UNC-backed or otherwise non-bindable Windows paths into a local Windows mount root, syncs artifacts back, and records staging status in capture output | `tests/Run-NIWindowsContainerCompare.Tests.ps1`, `tools/priority/__tests__/windows-docker-shared-surface-contract.test.mjs`, `tools/priority/__tests__/vi-history-local-proof-contract.test.mjs`, `TEST-WDSS-008` |
| Authoritative CI gate coverage | `vi-binary-gate.yml` routes the blocking binary-handling gate through `windows-ni-proof-reusable.yml`, which runs static invariants plus the hosted Windows NI preflight and compare proof without delegating authority to `pester-reusable.yml` | `tools/priority/__tests__/windows-ni-proof-workflow-contract.test.mjs`, `tools/priority/__tests__/windows-docker-shared-surface-contract.test.mjs`, `tests/ViBinaryHandling.Tests.ps1`, `TEST-WDSS-009` |
| Bounded timeout coverage | Hosted preflight and shared runtime-manager Docker commands fail closed on pull/probe timeout, and the reusable Windows NI proof workflow bounds the preflight step separately from the job timeout | `tests/Test-WindowsNI2026q1HostPreflight.Tests.ps1`, `tests/Invoke-DockerRuntimeManager.Tests.ps1`, `tools/priority/__tests__/windows-ni-proof-workflow-contract.test.mjs`, `TEST-WDSS-010` |
