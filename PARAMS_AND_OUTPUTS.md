<!-- markdownlint-disable-next-line MD041 -->
# Script Parameters & Outputs (LabVIEW 2025 / LVCompare CLI)

## tools/Warmup-LabVIEWRuntime.ps1

- **LabVIEWPath** (string, optional): explicit `LabVIEW.exe` path. When
  omitted, the script derives the canonical LabVIEW 2025 path from
  `LABVIEW_PATH` or by combining `ProgramFiles` (or `ProgramFiles(x86)`),
  the LabVIEW version (`MinimumSupportedLVVersion`, default 2025), and
  bitness.
- **LabVIEWBitness** (`32`|`64`, default 64): controls canonical path
  derivation when `LabVIEWPath` is not supplied.
- **MinimumSupportedLVVersion** (string, default `2025`): used when
  deriving the canonical path.
- **TimeoutSeconds** (int, default 30), **IdleWaitSeconds** (int, default
  2), **KeepLabVIEW** (switch), **StopAfterWarmup** (switch),
  **JsonLogPath** (string), **SnapshotPath** (string, default
  `tests/results/_warmup/labview-processes.json`), **SkipSnapshot**,
  **DryRun**, **KillOnTimeout**.
- **Environment**: expects `LABVIEW_PATH` (optional override) plus
  optional `LABVIEW_BITNESS`, `MINIMUM_SUPPORTED_LV_VERSION`, or
  `MINIMUM_SUPPORTED_LV_BITNESS`.
- **Outputs**: writes NDJSON events at `JsonLogPath` (default
  `tests/results/_warmup/labview-runtime.ndjson`), optional snapshot JSON,
  and a console summary. Leaves LabVIEW running unless `-StopAfterWarmup`
  is passed.

## tools/Prime-LVCompare.ps1

- **LVComparePath** (string, optional): path to `LVCompare.exe` (default
  canonical location or `LVCOMPARE_PATH`).
- **LabVIEWPath** (string, optional) and **LabVIEWBitness** (`32`|`64`,
  default 64): resolved exactly as in the warmup script.
- **BaseVi** and **HeadVi** (string, optional): default to `LV_BASE_VI`
  and `LV_HEAD_VI` or repo `VI1.vi` and `VI2.vi`.
- **DiffArguments** (string[]): extra CLI flags appended after `-lvpath`
  and canonical normalization flags (`-nobdcosm`, `-nofppos`, `-noattr`).
- **ExpectDiff**, **ExpectNoDiff** (switches), **TimeoutSeconds**
  (default 60), **KillOnTimeout**, **JsonLogPath** (NDJSON crumbs;
  default `tests/results/_warmup/prime-lvcompare.ndjson`), **LeakCheck**
  (switch), **LeakGraceSeconds** (double, default 0.5s), **LeakJsonPath**.
- **Environment**: `LABVIEW_PATH` (optional) and `LABVIEW_BITNESS`
  (optional) with canonical fallback to LabVIEW 2025.
- **Outputs**: exit code mirrors LVCompare (0 no diff, 1 diff, >1 error).
  When `LeakCheck` is used, writes `prime-lvcompare-leak.json`. NDJSON
  log includes plan, spawn, result, and leak-check events.

## tools/Invoke-LVCompare.ps1

- **LabVIEWExePath** (alias `LabVIEWPath`) and **LabVIEWBitness**
  (mandatory after resolution).
- **LVComparePath** (string, optional; alias `LVCompareExePath`): explicit
  `LVCompare.exe` path. Defaults to `LVCOMPARE_PATH`, `LV_COMPARE_PATH`,
  or the canonical install path when omitted.
- **BaseVi** and **HeadVi** (string, required).
- **Flags** (string[]) with **ReplaceFlags** (switch) customize LVCompare
  arguments in addition to `-lvpath`. Defaults include
  `-nobdcosm -nofppos -noattr` when `ReplaceFlags` is not supplied.
- **OutputDir** (string, default `tests/results/single-compare`):
  artifacts written here.
- **RenderReport** (switch), **JsonLogPath** (NDJSON crumb log),
  **Quiet**, **LeakCheck**, **LeakGraceSeconds** (default 0.5s),
  **LeakJsonPath**, **CaptureScriptPath** (for testing only),
  **Summary** (switch). `Summary` prints the console summary and appends
  to `$GITHUB_STEP_SUMMARY`.
- **Environment**: `LABVIEW_PATH` optional with canonical LabVIEW 2025
  fallback by bitness.
- **Outputs**:
  - `lvcompare-capture.json` (schema `lvcompare-capture-v1`, includes
    command, exitCode, duration). Required; script fails if missing.
  - `lvcompare-stdout.txt`, `lvcompare-stderr.txt`,
    `lvcompare-exitcode.txt` (from capture pipeline).
  - `compare-report.html` when `-RenderReport` is used and LVCompare
    produces output.
  - Optional NDJSON log (plan, spawn, result, leak-check).
  - Optional leak summary JSON (`compare-leak.json`).
  - Exit code equals the LVCompare exit code (0/1/other). With `-Summary`,
    prints `Compare Outcome: exit=... diff=... seconds=...` and appends to
    `$GITHUB_STEP_SUMMARY`.

## tools/TestStand-CompareHarness.ps1

- **BaseVi**, **HeadVi** (required), **LabVIEWExePath** (alias
  `LabVIEWPath`), **LabVIEWBitness** (defaults as above), **LVComparePath**
  (optional), **OutputRoot** (default `tests/results/teststand-session`,
  resolved to an absolute path), **RenderReport**, **CloseLabVIEW**,
  **CloseLVCompare**.
- **Behavior**: sequentially runs Warmup-LabVIEWRuntime -> Invoke-LVCompare
  -> optional closers. Writes a session index at
  `OutputRoot/session-index.json` with references to the warmup log
  (`_warmup/labview-runtime.ndjson`), compare log
  (`compare/compare-events.ndjson`), capture JSON, and report presence.
  Exit code equals the compare exit when available (defaults to 1 if the
  capture file is missing).
- **Artifacts**: under `OutputRoot` the harness writes `_warmup/...`,
  `compare/...`, and `session-index.json` summarizing the run.
- **Validation**: run `node tools/npm/run-script.mjs session:teststand:validate` to assert the
  harness output stays aligned with
  `docs/schema/generated/teststand-compare-session.schema.json` whenever
  parameters or warmup behaviour change.

## Environment Summary

- **LABVIEW_PATH**: optional explicit LabVIEW 2025 path. If unset,
  scripts derive the canonical path from `ProgramFiles` or
  `ProgramFiles(x86)` plus bitness and version.
- **LABVIEW_BITNESS**: optional default bitness when parameters omit it
  (32 or 64).
- **LABVIEW_VERSION** / **MINIMUM_SUPPORTED_LV_VERSION** (optional):
  provide version overrides for canonical resolution (defaults to 2025).
- **LVCOMPARE_PATH**: optional path to `LVCompare.exe` when not at the
  canonical location.

All scripts fail early with explicit messages when the derived LabVIEW
path does not exist (the expected canonical path is shown). Use
`RUNBOOK_COMPARE_DRIVER=1` to enable the new compare driver in the
integration runbook; otherwise it falls back to the legacy CompareVI path.
