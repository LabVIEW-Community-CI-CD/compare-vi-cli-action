# Windows Docker Shared Surface Control Plane

## Scope

This control plane covers the shared Windows Docker Desktop + pinned NI Windows
image surface that adjacent local proof packets should use before another
hosted rerun is chosen, and the hosted proof workflow that owns blocking CI
authority for Windows image-backed binary-handling lanes.

## Surface View

| Surface | Responsibility | Technology |
| --- | --- | --- |
| Readiness probe surface | Emit a bounded receipt for shared Windows Docker Desktop + NI image readiness | PowerShell + Docker |
| Bootstrap and preflight surface | Prepare and validate the Windows host deterministically | PowerShell + Docker |
| Bridge surface | Reach Windows-local PowerShell and Node execution from a Unix or WSL coordinator | Node.js + PowerShell |
| Path-hygiene surface | Detect synced or externally managed roots such as OneDrive-managed paths before live proof | Node.js |
| Windows-local staging surface | Stage UNC-backed or otherwise non-bindable Windows inputs and outputs into a local mount root for Docker consumption | PowerShell + Docker |
| Hosted CI authority surface | Route blocking Windows image-backed gates through the shared Windows NI proof workflow instead of the generic Pester reusable workflow | GitHub Actions + PowerShell |
| Local autonomy surface | Emit ranked local guidance, proof checks, and next-step handoffs for the shared surface | Node.js + assurance packet |

## Component View

| Component | Container | Responsibility |
| --- | --- | --- |
| `Invoke-PesterWindowsContainerSurfaceProbe.ps1` | Readiness probe surface | Emit `pester-windows-container-surface.json` with bounded surface states |
| `Test-WindowsNI2026q1HostPreflight.ps1` | Bootstrap and preflight surface | Emit deterministic Windows host preflight contracts |
| `Run-NIWindowsContainerCompare.ps1` | Bootstrap and preflight surface | Provide the bounded compare probe on the shared NI Windows image surface |
| `Run-NIWindowsContainerCompare.ps1` | Windows-local staging surface | Stage UNC-backed WSL container-bound paths into a Windows-local mount root and synchronize report artifacts back |
| `windows-ni-proof-reusable.yml` | Hosted CI authority surface | Reuse the hosted Windows NI proof contract across manual parity and blocking CI gates |
| `Test-VIBinaryHandlingInvariants.ps1` | Hosted CI authority surface | Emit the supporting static invariant contract without routing the gate through Pester |
| `windows-host-bridge.mjs` | Bridge surface | Resolve reachable Windows PowerShell/Node entrypoints and run governed Windows-local work from Unix or WSL |
| `windows-docker-shared-surface-local-ci.mjs` | Path-hygiene + local autonomy surfaces | Detect OneDrive-like risks, synthesize the packet, and emit next-step handoffs |

## Design Constraints

- The shared Windows surface should stay packetized separately from Pester and
  VI History.
- OneDrive-like managed roots should be treated as explicit proof risk on the
  shared surface instead of an incidental environment concern.
- The shared surface should remain the first-class owner of
  `windows-docker-desktop-ni-image` escalation semantics.
- Blocking CI lanes for Windows image-backed binary-handling proof should route
  through `windows-ni-proof-reusable.yml` and not through
  `.github/workflows/pester-reusable.yml`.
- When a reachable Windows Desktop exists behind Unix or WSL, the bridge
  surface should execute Windows-local probe and preflight work before the
  packet emits a host-unavailable escalation.
- UNC-backed WSL repo paths should never be passed straight to Docker bind
  mounts on the Windows surface; the staging surface should own that
  translation and synchronize the output back to the requested repo paths.
