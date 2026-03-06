<!-- markdownlint-disable-next-line MD041 -->
# Fixture Drift & Manifest Refresh

Canonical fixtures (`VI1.vi`, `VI2.vi`) are tracked by `fixtures.manifest.json` (bytes + sha256).
The validator keeps fixtures deterministic and records auto-refresh events for review.

## Validator overview

- Run locally: `pwsh -File tools/Validate-Fixtures.ps1 -Json`
- Key exit codes: `0` ok, `4` size issue, `6` hash mismatch, `5` multiple issues
- JSON output includes `summaryCounts` and `autoManifest` block (`written`, `reason`, `path`)

When both fixtures change, the validator treats it as deterministic drift and writes a new
manifest (`autoManifest.written=true`).

## CI usage

The Fixture Drift workflow:

- Runs strict and override validations (`strict.json`, `override.json`)
- Notes manifest refreshes in the job summary when `autoManifest.written` is true
- Uploads the refreshed manifest as an artifact

CI can gate on non-zero exit code or inspect `autoManifest.written` to flag drift.

## Docker runtime manager contract

Fixture Drift uses `tools/Invoke-DockerRuntimeManager.ps1` (schema `docker-runtime-manager@v1`) to
enforce Docker Desktop engine determinism before Windows-host comparison steps.

- Workflow job: `docker-runtime-manager` in `.github/workflows/fixture-drift.yml`
- Primary artifact: `results/fixture-drift/docker-runtime-manager.json`
- Windows lane context artifact:
  `results/fixture-drift/docker-runtime-manager-context.json`
- Windows runtime determinism snapshot:
  `results/fixture-drift/windows-runtime-determinism.json`

Dedicated Windows host lane name:

- `Fixture Drift (Docker Desktop Host - LabVIEW 2026 q1 windows)`

Windows lane container evidence (required for non-docs runs):

- Runs `tools/Run-NIWindowsContainerCompare.ps1` against fixture base/head copies.
- Enforces image match: `nationalinstruments/labview:2026q1-windows`.
- Fails the lane if container compare `gateOutcome` is not `pass`.
- Uploads container artifacts under:
  - `results/fixture-drift/ni-windows-container/ni-windows-container-capture.json`
  - `results/fixture-drift/ni-windows-container/compare-report.html`
  - `results/fixture-drift/ni-windows-container/runtime-determinism.json`
  - `results/fixture-drift/ni-windows-container/container-export/**`

Invoker lifecycle in the same lane is explicit and ordered:

- `Wire Invoker (start)` then `Ensure Invoker (start)` before drift execution.
- `Ensure Invoker (stop)` then `Wire Invoker (stop)` during teardown.

Reusable output keys emitted by the manager step:

- `manager_status`
- `manager_summary_path`
- `windows_image_digest`
- `linux_image_digest`
- `start_context`
- `final_context`

The Windows fixture lane consumes these fields into step summary output and injects them into
`session-index.json` under `runContext.dockerRuntimeManager` for downstream evidence review.

The manager also bootstraps NI images when missing (`docker pull`) and records local runtime probe
results per lane (`probes.<lane>.probe`), so evidence includes:

- host OS + Docker start/final context metadata
- local image presence and digest (`probes.<lane>.bootstrap.localDigest`)
- probe command outcome (`probes.<lane>.probe.status` / `exitCode`)

Safety mode for shared self-hosted runners:

- Fixture Drift runtime checks run in non-mutating mode (`ManageDockerEngine=false`).
- `tools/Assert-DockerRuntimeDeterminism.ps1` blocks host engine mutation actions unless
  `-AllowHostEngineMutation` is explicitly set (`Restart-Service`, `DockerCli -Shutdown`,
  `wsl --shutdown` remain opt-in only).

Quick local host bootstrap command:

```powershell
node tools/npm/run-script.mjs docker:ni:windows:bootstrap
```

## Manual manifest updates

For intentional fixture updates (outside automation):

```powershell
pwsh -File tools/Update-FixtureManifest.ps1 -Allow
```

Include `[fixture-update]` in the commit message to acknowledge the change.

## Optional pair digest block

`fixtures.manifest.json` can include a deterministic `pair` block (schema `fixture-pair/v1`). It
captures the combined base/head digest and expected outcome.

Fields:

- `basePath`, `headPath`, `algorithm` (sha256)
- `canonical`, `digest`
- `expectedOutcome` (`identical`, `diff`, `any`)
- `enforce` (`notice`, `warn`, `fail`)

Inject locally:

```powershell
pwsh -File tools/Update-FixtureManifest.ps1 -Allow -InjectPair `
  -SetExpectedOutcome diff `
  -SetEnforce warn
```

Validate with evidence:

```powershell
pwsh -File tools/Validate-Fixtures.ps1 -Json -RequirePair -FailOnExpectedMismatch `
  -EvidencePath results/fixture-drift/compare-exec.json
```

Evidence search order (when `-EvidencePath` omitted):

1. `results/fixture-drift/compare-exec.json`
2. Latest `tests/results/**/(compare-exec.json|lvcompare-capture.json)`

Outcome mapping: LVCompare exit code `0` → identical, `1` → diff, else `unknown` (or use the
`diff` boolean when available).
