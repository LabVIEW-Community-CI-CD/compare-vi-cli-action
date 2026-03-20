<!-- markdownlint-disable-next-line MD041 -->
# LabVIEW CLI Custom Operation Proof

This note defines the fail-closed proof helpers used to investigate
`LabVIEWCLI` custom-operation execution on the official NI `AddTwoNumbers`
example across both the native host plane and the pinned Windows container
mirror plane.

## Purpose

Use the proof helper when you need deterministic evidence for:

- implicit `LabVIEWCLI` path drift
- explicit `-LabVIEWPath` behavior on the LabVIEW 2026 host plane
- explicit `-LabVIEWPath` behavior inside `nationalinstruments/labview:2026q1-windows`
- `GetHelp.vi` vs headless `RunOperation.vi` behavior
- lingering `LabVIEW` / `LabVIEWCLI` residue after a hang
- whether a failure is host-native-specific or reproducible on the Windows
  container mirror

The helper always writes a machine-readable receipt and summary, even when the
proof ends blocked.

## Entry points

- Helper: `tools/Test-LabVIEWCLICustomOperationProof.ps1`
- Windows container runner: `tools/Run-NIWindowsContainerCustomOperation.ps1`
- Analysis module: `tools/LabVIEWCLICustomOperationProof.psm1`
- Receipt schema:
  `docs/schemas/labview-cli-custom-operation-proof-v1.schema.json`
- Focused test:
  `tests/LabVIEWCLICustomOperationProof.Tests.ps1`
- Focused Windows runner test:
  `tests/Run-NIWindowsContainerCustomOperation.Tests.ps1`

## Default behavior

Unless `-OperationDirectory` is supplied, the helper first scaffolds a
disposable workspace from the installed NI example under
`tests/results/_agent/custom-operation-proofs/<Operation>-<timestamp>/workspace`.

It then runs this scenario pack through the shared `Invoke-LVCustomOperation`
abstraction:

1. `default-help`
   - omit `-LabVIEWPath`
   - probe the implicit LabVIEW selection used by `LabVIEWCLI`
2. `explicit-help`
   - force the preferred LabVIEW 2026 path
   - run `GetHelp.vi`
3. `explicit-headless-run`
   - force the same LabVIEW 2026 path
   - run `RunOperation.vi` with `-x 1 -y 2 -LogToConsole true -Headless true`

When `-LabVIEWPath` is omitted, the helper prefers the LabVIEW 2026 32-bit host
plane when one is installed and falls back to the next available candidate.

When `-ExecutionPlane windows-container` is selected, the helper keeps both help
scenarios headless because LabVIEW 2026 Windows containers require `-Headless`
CLI execution.

The Windows container runner also assumes native `powershell` inside
`nationalinstruments/labview:2026q1-windows`; it must not assume `pwsh` exists
in that image.

## Residue policy

The helper records `LabVIEW` and `LabVIEWCLI` processes before and after each
scenario.

- It only force-cleans newly spawned residue.
- It does not kill pre-existing human-owned LabVIEW processes.
- A blocked proof still fails closed if newly spawned processes remain after
  cleanup.

## Logs and analysis

For each scenario, the helper copies matching temp logs into the per-run results
root and projects:

- observed `Using LabVIEW: "<path>"` values
- whether launch reached `LabVIEW launched successfully`
- whether completion text was observed

The final receipt computes root-cause candidates for:

- `default-path-drift`
- `custom-operation-loading`
- `headless-interactive-mismatch`
- `host-plane-32bit-startup`

For Windows container runs, the receipt also records:

- `executionPlane = windows-container`
- `containerImage = nationalinstruments/labview:2026q1-windows`
- `preflightPath` from the Windows Docker Desktop host-plane preflight
- per-scenario `containerCapturePath`

## Usage

Run the live host proof:

```powershell
node tools/npm/run-script.mjs history:custom-operation:proof
```

Run the live Windows container mirror proof:

```powershell
node tools/npm/run-script.mjs history:custom-operation:proof:windows
```

Preview the disposable plan without executing LabVIEW:

```powershell
pwsh -NoLogo -NoProfile -File tools/Test-LabVIEWCLICustomOperationProof.ps1 `
  -DryRun
```

Use an explicit custom operation workspace instead of the scaffolded NI example:

```powershell
pwsh -NoLogo -NoProfile -File tools/Test-LabVIEWCLICustomOperationProof.ps1 `
  -OperationDirectory tests/results/_agent/custom-operation-scaffolds/manual-authoring `
  -LabVIEWPath "C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe"
```

Run the Windows container proof against an explicit in-container LabVIEW path:

```powershell
pwsh -NoLogo -NoProfile -File tools/Test-LabVIEWCLICustomOperationProof.ps1 `
  -ExecutionPlane windows-container `
  -WindowsContainerLabVIEWPath "C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe"
```

## Receipt

Successful or blocked runs emit `labview-cli-custom-operation-proof@v1` with:

- proof status
- execution plane (`host` or `windows-container`)
- explicit LabVIEW path used for forced scenarios
- container image and preflight path when the Windows mirror plane is used
- scaffold receipt path when applicable
- per-scenario preview/invocation results
- copied log inventory
- PID tracker payload
- lingering-process cleanup outcomes
- projected root-cause candidates

## Boundary

These helpers prove the host plane and the Windows container mirror plane for
the official NI example.

- It does not make repo-owned custom operation payloads promotable by itself.
- It does not replace the scaffold helper from `#1471`.
- The host plane and Windows container plane should be compared before blaming
  native 32-bit host behavior.
- The Windows mirror plane is pinned to
  `nationalinstruments/labview:2026q1-windows`; do not drift that image without
  a deliberate contract change.

## Current conclusion

As of March 20, 2026, this repo has deterministic evidence that:

- the native LabVIEW 2026 x86 host plane can hang on the official
  `AddTwoNumbers` custom operation helper scenarios
- the Windows 64-bit container mirror plane succeeds on the same host against
  `nationalinstruments/labview:2026q1-windows`

That means the remaining suspicion is narrower than "LabVIEWCLI is broken" or
"the NI example is invalid". The current evidence points back toward native
host-plane behavior, especially the 32-bit host surface, rather than a general
container-plane failure.
