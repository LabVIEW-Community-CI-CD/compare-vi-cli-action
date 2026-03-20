<!-- markdownlint-disable-next-line MD041 -->
# LabVIEW CLI Custom Operation Proof

This note defines the fail-closed proof helper used to investigate
`LabVIEWCLI` custom-operation execution on the official NI `AddTwoNumbers`
example.

## Purpose

Use the proof helper when you need deterministic evidence for:

- implicit `LabVIEWCLI` path drift
- explicit `-LabVIEWPath` behavior on the LabVIEW 2026 host plane
- `GetHelp.vi` vs headless `RunOperation.vi` behavior
- lingering `LabVIEW` / `LabVIEWCLI` residue after a hang

The helper always writes a machine-readable receipt and summary, even when the
proof ends blocked.

## Entry points

- Helper: `tools/Test-LabVIEWCLICustomOperationProof.ps1`
- Analysis module: `tools/LabVIEWCLICustomOperationProof.psm1`
- Receipt schema:
  `docs/schemas/labview-cli-custom-operation-proof-v1.schema.json`
- Focused test:
  `tests/LabVIEWCLICustomOperationProof.Tests.ps1`

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

## Usage

Run the live host proof:

```powershell
node tools/npm/run-script.mjs history:custom-operation:proof
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

## Receipt

Successful or blocked runs emit `labview-cli-custom-operation-proof@v1` with:

- proof status
- explicit LabVIEW path used for forced scenarios
- scaffold receipt path when applicable
- per-scenario preview/invocation results
- copied log inventory
- PID tracker payload
- lingering-process cleanup outcomes
- projected root-cause candidates

## Boundary

This helper proves the host-plane behavior of the official NI example.

- It does not make repo-owned custom operation payloads promotable by itself.
- It does not replace the scaffold helper from `#1471`.
- It exists so `#1472` can be closed with deterministic evidence instead of ad
  hoc terminal transcripts.
