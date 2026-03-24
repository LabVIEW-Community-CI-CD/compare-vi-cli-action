<!-- markdownlint-disable-next-line MD041 -->
# Self-Hosted CI Setup

Provision this machine as the canonical compare capability host, not as a
generic shared workstation runner. GitHub Actions should land work on the host
through a small ingress label surface, then the governed execution-cell and
Docker-lane helpers decide how the work runs locally.

## Installations

1. GitHub Actions runner (service mode).
2. LabVIEW 2026 64-bit and 32-bit native paths when the host will serve dual-plane parity.
3. PowerShell 7 (`pwsh`).
4. Git + Node.js.
5. Docker engine reachable through the governed host policy used by the Docker-lane handshake.

## Runner configuration

- Canonical install root: `C:\actions-runner\comparevi-capability-ingress`
- Canonical runner role: compare capability ingress host
- Canonical service model: delayed-auto-start Windows service
- Required labels:
  - `self-hosted`
  - `Windows`
  - `X64`
  - `comparevi`
  - `capability-ingress`
- Optional capability labels:
  - `labview-2026`
  - `lv32`
  - `docker-lane`
  - `teststand`
- Prefer a small number of coarse GitHub runner labels over one runner registration per background agent.
- Isolated Docker lanes should be leased locally through the Docker-lane handshake helper instead of by creating a
  permanent GitHub Actions runner service for each agent.
- Service account requires access to VI fixtures and temporary directories.
- Environment variables (system scope recommended):
  - `LV_BASE_VI`, `LV_HEAD_VI` (sample VIs).
  - `LV_NO_ACTIVATE=1`, `LV_SUPPRESS_UI=1`, `LV_CURSOR_RESTORE=1`.
  - `WATCH_RESULTS_DIR` (optional) for watcher output.
- Secrets/variables:
  - Repo secret `XCLI_PAT` (scopes: `repo`, `actions:write`) for command dispatch feedback.

## Verification

```powershell
Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
[Environment]::GetEnvironmentVariable('LV_BASE_VI', 'Machine')
[Environment]::GetEnvironmentVariable('LV_HEAD_VI', 'Machine')
node tools/npm/run-script.mjs env:labview:2026:host-planes
pwsh -NoLogo -NoProfile -File tools/Assert-RunnerLabelContract.ps1 `
  -Repository LabVIEW-Community-CI-CD/compare-vi-cli-action `
  -RunnerName GHOST-comparevi-capability-ingress `
  -RequiredLabel capability-ingress `
  -Token (gh auth token)
node tools/npm/run-script.mjs priority:lane:docker:handshake -- --action request --lane-id docker-agent-check-01 --agent-id operator --agent-class other --capability docker-lane
```

Inside a GitHub Actions job, the same helper automatically switches to
run-jobs validation through `GITHUB_RUN_ID`, `RUNNER_NAME`, and
`GITHUB_TOKEN`.

Dispatch `Pester (self-hosted, real CLI)` manually to confirm environment validation and tests pass.

When the host is part of the canonical isolated lane group, treat the generated
host-plane report as the OS/build source of truth:

- `tests/results/_agent/host-planes/labview-2026-host-plane-report.json`
- `host.osFingerprint.fingerprintSha256`
- `host.osFingerprint.isolatedLaneGroupId`
- `host.osFingerprint.canonical.version`
- `host.osFingerprint.canonical.buildNumber`
- `host.osFingerprint.canonical.ubr`

Future host refreshes and isolated lane groups should compare against that
fingerprint before blaming LabVIEW, Docker, or runner drift on the workload
itself.

When the host also carries deterministic compare tooling, the TestStand harness
is a supported native-plane consumer:

- `pwsh -NoLogo -NoProfile -File tools/TestStand-CompareHarness.ps1`
  `-BaseVi <base> -HeadVi <head> -OutputRoot`
  `tests/results/teststand-session -Warmup detect -RenderReport`

That harness does not define a separate runner class. It consumes one of the
native LabVIEW planes and should be attributed to the same host OS fingerprint
and isolated lane group.

Self-hosted compare workflows should target:

- `runs-on: [self-hosted, Windows, X64, comparevi, capability-ingress]`

Add capability labels only when a job truly needs them. `capability-ingress` is
the stable ingress requirement; execution cells and Docker lanes remain the
local isolation mechanism behind it.

## Maintenance

- Keep LabVIEW and Windows patched.
- Monitor runner health (Actions → Runners).
- Rotate PATs and verify secrets annually.
- Periodically refresh fixture VIs and environment variables.
- After a Windows upgrade, rerun
  `node tools/npm/run-script.mjs env:labview:2026:host-planes` and compare the
  previous versus current `host.osFingerprint` values before reclassifying lane
  regressions. A changed fingerprint means the canonical host OS baseline moved.

Further reading: [`docs/E2E_TESTING_GUIDE.md`](./E2E_TESTING_GUIDE.md), [`docs/ENVIRONMENT.md`](./ENVIRONMENT.md).
