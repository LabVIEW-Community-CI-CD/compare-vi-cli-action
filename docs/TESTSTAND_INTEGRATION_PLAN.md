# TestStand Wrapper Integration Plan

This document captures the path for making the existing `tools/TestStand-CompareHarness.ps1` a first-class execution option both locally and inside CI. The harness already orchestrates LabVIEW warmup, runs LVCompare deterministically, and emits an index describing the session. The work below focuses on productizing that flow so it mirrors the behaviour of `Invoke-PesterTests.ps1`.

## 1. Local enablement

### 1.1 Discover prerequisites

- LabVIEW 2025 (64-bit) must be installed locally, or the user must provide the explicit `LabVIEW.exe` path via `-LabVIEWExePath` or `LABVIEW_PATH`.
- LVCompare must live at the canonical install path or be supplied with `-LVComparePath`.
- Sample VIs already exist in the repo (`VI1.vi`, `VI2.vi`) and can be copied into `$TestDrive` for smoke tests.

### 1.2 Baseline command

```powershell
pwsh -NoLogo -NoProfile -File tools/TestStand-CompareHarness.ps1 `
  -BaseVi (Resolve-Path .\VI1.vi) `
  -HeadVi (Resolve-Path .\VI2.vi) `
  -OutputRoot tests/results/teststand-session `
  -RenderReport `
  -CloseLabVIEW `
  -CloseLVCompare
```

This produces:

- `_warmup/labview-runtime.ndjson`
- `compare/lvcompare-capture.json`, `compare/compare-events.ndjson`,
  `compare/_staging/compare/compare-report.html`
- `session-index.json` summarising the run

> **Note**: `-CloseLabVIEW` / `-CloseLVCompare` now queue post-run cleanup requests. The helpers do not invoke the close scripts inline; instead `tools/Post-Run-Cleanup.ps1` consumes the requests after `Invoke-PesterTests.ps1` completes, guaranteeing a single g-cli invocation per job.

### 1.3 Harmonise outputs with dispatcher expectations

1. Create a helper (e.g., `tools/Promote-TestStandSession.ps1`) that:
   - Copies key artifacts into `tests/results/<category>` (or `tests/results/teststand`) so the existing `Write-ArtifactManifest` and step summaries stay valid.
   - Invokes `Invoke-PesterTests.ps1` summary helpers (`Write-SelectedTestsSummary`, `Invoke-RerunHintWhenNoIntegration`) with synthetic data so rerun UX remains consistent.
2. Extend `Invoke-PesterTests.ps1` with a new switch `-UseTestStandHarness` that, when set:
   - Resolves the discovery manifest as usual.
   - For each selected test file, maps the `.Tests.ps1` to a concrete pair of VIs (initial support can use `LV_BASE_VI`/`LV_HEAD_VI` produced by the fixture-prep step).
   - Calls `TestStand-CompareHarness.ps1` instead of invoking Pester.
   - Records results in the JSON summary schema so downstream jobs continue to operate.
3. Add README / docs snippets guiding the local developer through prerequisites, environment variables, and expected outputs. Link this doc from `README.md` and from `PARAMS_AND_OUTPUTS.md`.

### 1.4 Validation loop

| Command | Purpose |
| --- | --- |
| `npm run tests:discover` | Ensure the TypeScript manifest is current before mapping tests to harness inputs. |
| `pwsh -File tools/TestStand-CompareHarness.ps1 ...` | Baseline manual smoke. |
| `pwsh -File Invoke-PesterTests.ps1 -IncludeIntegration false -UseTestStandHarness -UseDiscoveryManifest` | End-to-end local run that mirrors CI. |
| `pwsh -File tools/Quick-DispatcherSmoke.ps1 -Keep` | Verify workflow helpers accept the harness outputs. |

### 1.5 Acceptance delta guardrails

Before enabling the harness end-to-end, codify the updated acceptance criteria in `develop` so reruns stay deterministic:

- Dispatcher runs now emit a dedicated “Selected Tests” block and always append the `/run orchestrated … include_integration=false` hint when integration is disabled. The helpers live in `Invoke-PesterTests.ps1` and are exercised by `tests/Invoke-PesterTests.Summary.Tests.ps1`.
- When `IncludeIntegration=false`, the dispatcher exports `LVCI_FORBID_COMPARE=1` and `scripts/CompareVI.psm1` blocks LVCompare with a summary notice. This codifies the existing operator expectation that we do not launch LVCompare outside integration runs.
- `tools/RunnerInvoker/RunnerInvoker.psm1` records an invoker `runId` in `tests/results/_invoker/current-run.json`, request logs, and single-compare state to keep telemetry correlated. The schema is tracked at `docs/schema/generated/pester-invoker-current-run.schema.json`, with coverage in the RunnerInvoker unit suites.
- Close helpers execute solely via `tools/Post-Run-Cleanup.ps1`, which reads request crumbs under `tests/results/_agent/post/requests` (populated by the TestStand harness, integration loop, etc.) and uses `tools/Once-Guard.psm1` to ensure each action runs once per job.

## 2. GitHub Actions alignment

### 2.1 Add harness mode

- Introduce a job variable (`TESTSTAND_MODE=1`) in `.github/workflows/ci-orchestrated.yml` and `.github/workflows/pester-reusable.yml`.
- When the variable is set:
  - Replace `Invoke-PesterTests.ps1` calls with the harness helper described above.
  - Skip LVCompare gating in `Invoke-PesterTests.ps1` (the harness takes care of warmup and diff detection).
  - Preserve existing environment safeguards (session-lock, leak checks, stuck-guard) by wrapping the harness call instead of bypassing orchestration altogether.

### 2.2 Telemetry

- Update `tools/Ensure-SessionIndex.ps1` to recognise the `teststand-compare-session/v1` schema and emit summary lines (`exit`, `diff`, elapsed seconds).
- Amend the Summary appender to group TestStand runs under a dedicated heading (`### TestStand Compare Session`).
- Capture the warmup/compare NDJSON files via the artifact manifest so they are available for debugging.

### 2.3 Gradual rollout

1. Land the feature behind a repo variable (`vars.TESTSTAND_HARNESS=0`), defaulting to the current Pester path.
2. Add a nightly workflow or manual dispatch (`/run orchestrated strategy=teststand`) that exercises the harness end-to-end.
3. Once the telemetry is stable, flip the default on self-hosted runners, keeping the option to fall back by toggling the variable.

## 3. Documentation & follow-up

- Create a quick-start doc (`docs/TESTSTAND_QUICKSTART.md`) derived from the steps above.
- Update `AGENT_HANDOFF.txt` guidance to mention the harness mode and how to toggle it.
- Track remaining tasks in the standing-priority issue (or a linked issue) for visibility: wiring unit tests, user documentation, workflow feature flag toggles.

## 4. Open questions

- Do we need the harness to support integration test matrices (multiple VI pairs per run), or is a single compare sufficient?
- Should the harness emit TAP/JUnit-compatible results so downstream analytics continue to function without translation?
- How do we best surface LabVIEW/LVCompare errors (e.g., via GitHub annotations)?

Addressing these items will give us a consistent TestStand-driven workflow that works locally and in CI without compromising the deterministic guarantees we rely on today.

