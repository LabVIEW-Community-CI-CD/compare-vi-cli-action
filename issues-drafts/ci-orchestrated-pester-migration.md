# CI Orchestrated → Pester-First Migration (draft)

## Why refactor?
- The current `.github/workflows/ci-orchestrated.yml` stitches together bespoke PowerShell scripts, node utilities, Docker shims, and Pester invocations. We pay a coordination tax every time we adjust orchestration logic, add telemetry, or stabilize reruns.
- We already invested heavily in Pester wrappers (`Invoke-PesterTests.ps1`, the staged test suites, agent telemetry appenders, etc.). If the GitHub workflow delegated each stage to tagged Pester blocks, we would get deterministic reporting, schema-and-artifact plumbing “for free,” plus easier local reproduction (`pwsh -File Invoke-PesterTests.ps1 -IncludePatterns …`).
- A single orchestration surface simplifies future debt payments: less composite-action maintenance, quicker hook parity, easier session-index updates, and more straightforward secret handling (everything stays in the Pester runspace).

## Current workflow audit (abridged)
| Job | Purpose | Primary scripts / actions today | Pester coverage? |
| --- | --- | --- | --- |
| `normalize` (ubuntu) | Normalize inputs (booleans, provenance) before fan-out | `bool-normalize` composite, `tools/Write-RunProvenance.ps1` | No |
| `lint` (ubuntu) | Actionlint, Docker `Run-NonLVChecks`, markdownlint, CLI build/publish, watcher sanity | direct shell, `tools/Run-NonLVChecksInDocker.ps1`, node scripts, `tools/Update-SessionIndexWatcher.ps1` | Partial (only downstream checks have Pester) |
| `preflight` (hosted Windows) | Hosted runner health, LVCompare presence, idle LabVIEW gate | `tools/Collect-RunnerHealth.ps1`, inline script | No |
| `probe` (self-hosted Windows) | Interactivity probe before switching to single strategy | `tools/Write-InteractivityProbe.ps1`, `Collect-RunnerHealth.ps1` | No |
| `pester-category` (self-hosted Windows) | Matrixed deterministic categories (dispatcher, fixtures, etc.) | `Invoke-PesterTests.ps1` with include/exclude patterns + fixture preparation | Yes (already Pester driven) |
| `drift` (self-hosted Windows) | Fixture drift sweep/report | `./.github/actions/fixture-drift` (wrapper around `tools/Invoke-FixtureViDiffs.ps1`, `Render-IconEditorFixtureReport.ps1`, etc.) | Partial (core scripts have tests but orchestrator not Pesterized) |
| `windows-single` (self-hosted Windows) | Serial Pester run with traceability + dashboards | `Invoke-PesterTests.ps1` (tag loop) | Yes |
| `publish` (ubuntu) | Session index ingestion, watcher publish, rerun hints | `tools/Update-SessionIndexWatcher.ps1`, `tools/Invoke-DevDashboard.ps1`, node watchers | Partial |

## Target architecture
1. **Single Pester entry point** per strategy (matrix vs single) invoked by the workflow. The workflow jobs become thin wrappers that call `pwsh Invoke-OrchestratedSuite.ps1 -Suite lint`, `… -Suite drift`, etc. These entry points internally call `Invoke-PesterTests.ps1` with tags like `Lint`, `Preflight`, `Drift`, `Publish`.
2. **Pester blocking**: Each logical stage becomes a `Describe` block tagged with the stage name. Within each `It`, we shell out to the existing script (e.g., `tools/Run-NonLVChecksInDocker.ps1`) and capture exit codes/logs via Pester’s `Should -Not -Throw` semantics. Artifacts are tracked by pointing `Invoke-PesterTests.ps1`’s `-ResultsPath` at the existing directories (`tests/results/lint`, etc.).
3. **Strategy selection**: Reuse current `normalize` outputs, but pass them as parameters to the orchestrating Pester suites instead of separate jobs. The GitHub workflow shrinks to:
   - `lint-suite` (ubuntu) → `Invoke-PesterTests.ps1 -IncludePatterns 'Lint.*'`
   - `windows-preflight` (hosted) → `Invoke-PesterTests.ps1 -IncludePatterns 'Preflight.*'`
   - `matrix-suite` (self-hosted) → `Invoke-PesterTests.ps1 -IncludePatterns 'Matrix.*'`
   - `single-suite` (self-hosted) → `Invoke-PesterTests.ps1 -IncludePatterns 'Single.*'`
   - `post-suite` (ubuntu) → `Invoke-PesterTests.ps1 -IncludePatterns 'Publish.*'`
   Concurrency / needs relationships mirror today’s job graph, but the only shell steps in the workflow are the Pester invocations plus artifact uploads.
4. **Artifacts & telemetry**: Each Pester suite writes to its existing `RESULTS_DIR`. The Pester configuration ensures NUnit XML, JSON summary, session index and dashboards persist. Where we previously relied on `actions/upload-artifact`, we trigger the upload directly from Pester via helper cmdlets (or keep a single upload step after the Pester call pointing at the populated directory).
5. **Watcher & Docker flows**: Wrap node/Docker commands in helper `It` blocks:
   ```powershell
   Describe 'Lint Suite' -Tag 'Lint','Docker' {
     It 'runs non-LV checks in Docker' {
       & pwsh -File 'tools/Run-NonLVChecksInDocker.ps1' @params | Should -Not -Throw
     }
   }
   ```
   Any structured outputs (watcher JSON, CLI meta) are placed under the suite’s results directory so Pester’s artifact hooks include them automatically.

## Migration steps
1. **Author new orchestrator module** (`tools/orchestrated/Invoke-OrchestratedSuite.psm1`):
   - Expose `Invoke-OrchestratedSuite -Suite lint|preflight|matrix|single|publish` → sets up environment variables, calls `Invoke-PesterTests.ps1` with stage-specific include patterns, ensures results directories exist.
   - Provide shared helpers for shelling out (wrapping exit codes, logging to `$PesterOutput`).
2. **Create Pester suites**:
   - `tests/Orchestrated.Lint.Tests.ps1`: capture actionlint install/run, Docker checks, CLI validation, watchers, markdownlint, session-index merge.
   - `tests/Orchestrated.Preflight.Tests.ps1`: wrap runner health, LVCompare checks.
   - `tests/Orchestrated.Matrix.Tests.ps1`: existing category tests already cover this; ensure tags align with new orchestrator naming.
   - `tests/Orchestrated.Drift.Tests.ps1`: call existing fixture drift orchestrator from within Pester (or break drift composite into script we can call directly).
   - `tests/Orchestrated.Single.Tests.ps1`: largely existing `windows-single` content (ensure gating logic expressed via `Context`/`It`).
   - `tests/Orchestrated.Publish.Tests.ps1`: watchers, rerun hints, dashboards, session-index post.
3. **Refactor composite actions**: Many GitHub composite actions (wire probes, ensure-invoker, prepare-fixtures) can be invoked from Pester by importing the underlying scripts/modules. For composites that do not add logic beyond shell execution, replace them with direct script calls to avoid needing the workflow wrapper.
4. **Shrink workflow**:
   - Replace multi-step jobs with a single step: `pwsh -File tools/orchestrated/Invoke-OrchestratedSuite.ps1 -Suite lint`.
   - Keep artifact uploads / concurrency semantics identical.
   - Keep matrix vs single gating but base it on orchestrator outputs (Pester can emit `GITHUB_OUTPUT` values via `Write-Output 'ready=true'` when needed).
5. **Telemetries & docs**: Update developer docs to point contributors at the new suite entry points (`Invoke-OrchestratedSuite -Suite lint` etc.). Ensure session index, dev dashboards, and watcher JSON continue to flow (Pester tests should write them; the workflow just uploads).

## Outstanding gaps / risks
- **Composite action parity**: Some actions perform more than shell out (e.g., wiring session index, uploading artifacts). We either replicate their logic in reusable PowerShell modules or invoke them via `pwsh -c "gh workflow run …"` which defeats the refactor. Need to catalog each composite and extract script equivalents where missing.
- **Node watchers & Docker**: Running Node/Docker commands from Pester is straightforward, but we must ensure their stdout/stderr doesn’t break Pester’s format and that exit codes propagate correctly. Wrapping them in helper cmdlets with robust error handling is essential.
- **Self-hosted runner safeguards**: Today’s workflow uses wire-probe / ensure-invoker actions sprinkled throughout. We’ll need Pester-friendly wrappers that maintain the same telemetry and failure semantics (including uploading boot logs and wire probe files).
- **Execution timeouts**: Pester runs are single PowerShell processes; long-running external commands must stream output to avoid hitting command timeouts. We may need to extend `Invoke-CommandWithRetry` helpers or run some tasks as background jobs.
- **Gradual migration path**: To avoid a risky “big bang,” consider first wrapping a single job (e.g., `lint`) using the new Pester suite while leaving other jobs untouched. Once validated, migrate the remaining jobs iteratively.

## Next steps
1. Finalize the suite taxonomy and tag conventions (`Lint`, `Preflight`, `Matrix`, `Drift`, `Single`, `Publish`).
2. Build the orchestrator module + helpers (include generic packed-library build helper consumed by current icon-editor tests so future packages can reuse it).
3. Port the `lint` job as the first proof-of-concept (low LabVIEW interaction, high payoff).
4. Expand to hosted preflight and publish jobs.
5. Migrate self-hosted matrix/single runs once we are confident the invoker wiring works from Pester.
6. Retire redundant composite actions and trim the GitHub workflow to minimal shell wrappers plus artifact uploads.

## Icon Editor VIPM build helper split (notes)
- Current packaging path already leans on `tools/vendor/IconEditorPackaging.psm1` (`Invoke-IconEditorVipPackaging`). For parity with the new `VipmDependencyHelpers`, introduce a `VipmBuildHelpers` module that:
  - wraps VIPM CLI readiness checks, modify/build/close invocations, and telemetry writing into reusable functions (`Invoke-VipmPackageBuild`, `Write-VipmBuildTelemetry`, etc.).
  - exposes display-only mode so we can list packaging artifacts without re-running VIPM.
- Refactor `tools/icon-editor/Invoke-IconEditorBuild.ps1` so the “Packaging icon editor VIP...” block simply prepares argument arrays and calls `Invoke-VipmPackageBuild`.
- Update tests to cover the new helper (similar to `tests/VipmDependencyHelpers.Tests.ps1`) and ensure `tests/Invoke-IconEditorVipPackaging.Tests.ps1` stays wired to the helper layer.
- Once helpers exist, consider trimming `.github/actions/build-vi-package/build_vip.ps1` to a thin wrapper (matching Apply-VIPC deprecation).
