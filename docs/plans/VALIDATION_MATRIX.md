<!-- markdownlint-disable-next-line MD041 -->
# Validation Matrix

Baseline expectations for the primary validation entry points tracked by standing priority #127. Use this as the
single source of truth when deciding which helper to run locally, invoke from VS Code tasks, or coordinate inside CI.

## Quick Reference

- **`tools/PrePush-Checks.ps1`**
  - Scope: workflow linting (`actionlint`).
  - Typical invocation: `pwsh -File tools/PrePush-Checks.ps1`.
  - Exit semantics: `0` = clean, non-zero = lint failure.
  - Artifacts: none (console only).
- **`Invoke-PesterTests.ps1`**
  - Scope: unit plus integration Pester suites.
  - Typical invocation: `pwsh -File Invoke-PesterTests.ps1 -IntegrationMode exclude`.
  - Exit semantics: `0` = pass, `1` = failures/errors.
  - Artifacts: `tests/results/pester-*`.
  - Platform note: install PowerShell 7 (`pwsh`) on macOS/Linux; when LabVIEW is unavailable, run the command
    without leak-cleanup switches until parity wiring lands.
- **`tools/Run-NonLVChecksInDocker.ps1`**
  - Scope: containerised lint, docs links, workflow drift, CLI build.
  - Typical invocation: `pwsh -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage`.
  - Exit semantics: first failing container exit (`0` happy, `3` = drift).
  - Artifacts: container logs, optional `dist/comparevi-cli/*`.
- **`tools/Start-IntegrationGated.ps1`**
  - Scope: orchestrated integration gate with watcher + auto-push.
  - Typical invocation: `pwsh -File tools/Start-IntegrationGated.ps1 -AutoPush -Start -Watch`.
  - Exit semantics: propagates the underlying gate (Pester + watcher).
  - Artifacts: session index + watcher telemetry.

## `tools/PrePush-Checks.ps1`

Audience: anyone touching `.github/workflows/**`.

- **What it does** – Locates (or installs) the platform-appropriate `actionlint` binary via `Resolve-ActionlintPath`
  and runs it against the repository workflows.
- **Inputs** – Optional `-ActionlintVersion` and `-InstallIfMissing`. Defaults keep parity with CI (1.7.7 as of this
  document). No additional env vars required.
- **Expected output** – Streams `actionlint` diagnostics to the console; no files are written. Successful runs finish
  quickly (<10 seconds on the tools image cache).
- **Failure modes** – Missing binary (when `-InstallIfMissing:$false`), lint errors, or transient download failures.
  Non-zero exit codes block pre-push hooks and VS Code tasks.
- **When to run** – Before pushing workflow changes, before dispatching a `priority:handoff-tests` suite, or when the
  priority router lists `validate:lint` at the top.

## `Invoke-PesterTests.ps1`

Audience: local validation for PowerShell unit/integration suites and leak detection.

- **What it does** – Pester v5 dispatcher with first-class integration toggles, leak detection (`-DetectLeaks`,
  `-KillLeaks`, `-CleanLabVIEW`), artifact tracking, and optional discovery manifests.
- **Inputs** – Key switches:
  - `-IntegrationMode auto|include|exclude` (prefer over `-IncludeIntegration`).
  - `-DetectLeaks -KillLeaks -CleanLabVIEW -CleanAfter` when validating LabVIEW hygiene.
  - `-ResultsPath` (defaults to `tests/results`) and `-JsonSummaryPath` for machine-readable summaries.
  - Pattern filters (`-IncludePatterns`, `-ExcludePatterns`) when chasing a single module.
- **Expected output** - Writes `pester-summary.json`, `pester-results.xml`, `pester-artifacts.json`, and plain-text
  summaries under `tests/results/`. Leak sweeps append to the GitHub Step Summary when available.
- **Failure modes** - Test failures (exit `1`), timeout guard triggers, or lingering LabVIEW/LVCompare processes when
  leak enforcement is enabled.
- **When to run** - After code changes that impact cmdlets/modules, before collecting integration gate baselines, or in
  response to red CI Pester jobs. Pair with `tools/Run-LocalBackbone.ps1` when exercising extended leak handling.
- **Runtime** - The `-IntegrationMode exclude` sweep currently exercises ~350 tests in about eight minutes on the
  Windows runner; plan accordingly when wiring this into VS Code tasks.
- **Leak handling** - The bundled VS Code task now runs with `-DetectLeaks -KillLeaks -CleanLabVIEW -CleanAfter` so
  LabVIEW/LVCompare processes are cleaned up automatically after the sweep.

### Pester invocation cheat sheet

- **Fast unit sweep** – `pwsh -File Invoke-PesterTests.ps1 -IntegrationMode exclude` (skips Integration-tagged specs).
- **Full coverage** –
  `pwsh -File Invoke-PesterTests.ps1 -IntegrationMode include -DetectLeaks -KillLeaks -CleanLabVIEW -CleanAfter`
  (enforces leak cleanup).
- **Targeted pattern** – `pwsh -File Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*' -IntegrationMode auto`
  (combine with `-UseDiscoveryManifest` when available).

## `tools/Run-NonLVChecksInDocker.ps1`

Audience: contributors without the full local toolchain or anyone mirroring CI behaviour.

- **What it does** – Spins up Docker containers for `actionlint`, `markdownlint`, documentation link checks, workflow
  drift detection, and optional CompareVI CLI builds. Supports the published tools image (`-UseToolsImage`) or
  per-check public images.
- **Inputs** – Common switches:
  - `-UseToolsImage [-ToolsImageTag <tag>]` to route everything through the curated tools container (honours
    `COMPAREVI_TOOLS_IMAGE`).
  - `-PrioritySync` to run `priority:sync` inside the container (requires `GH_TOKEN`).
  - `-FailOnWorkflowDrift` to treat exit code `3` as fatal locally.
  - Skip flags (`-SkipActionlint`, `-SkipMarkdown`, `-SkipDocs`, `-SkipWorkflow`, `-SkipDotnetCliBuild`) for tight
    loops.
- **Expected output** - Console logs reflect each container invocation. The CLI build emits `dist/comparevi-cli/*` when
  enabled. Workflow drift uses ruamel.yaml or the tools image helper and will leave pending git changes when drift is
  real.
- **Failure modes** - Missing Docker daemon, authentication gaps (when the tools image is private), or missing GH
  tokens during priority sync. Exit code is the first failing container code.
- **When to run** - Before publishing documentation, when validating the tools image, or after editing workflows to
  confirm round-trip stability.
- **Cleanup tip** - Remove the generated `dist/comparevi-cli` directory after validation to keep the working tree clean.
- **Automation** - Trigger the `Tools Parity (Linux)` workflow (`.github/workflows/tools-parity.yml`) for a hosted
  Ubuntu run that uploads Docker version + parity logs. macOS parity remains a manual verification (see
  `docs/knowledgebase/DOCKER_TOOLS_PARITY.md` for contribution notes).
- **Further reading** - `docs/knowledgebase/DOCKER_TOOLS_PARITY.md` captures environment prerequisites, expected
  artifacts, and cleanup guidance.

## `tools/Start-IntegrationGated.ps1`

Audience: engineers running the full integration gate (auto-push + watcher + session-index updates) outside GitHub.

- **Status** – Command is referenced throughout the standing priority but is not yet committed to the repository. Treat
  this section as the working contract while the script lands.
- **Planned behaviour** – Orchestrates `Invoke-PesterTests.ps1` (integration mode) with LabVIEW leak mitigation, runs
  the session-index updater, and dispatches the REST watcher with `-AutoPush -Start -Watch`.
- **Expected inputs** – `-AutoPush` (enable git push back to the working branch after green), `-Start` (begin the gate),
  `-Watch` (attach watcher telemetry). Additional toggles should pipe through to the dispatcher (integration mode) and
  to `tools/Run-NonLVChecksInDocker.ps1` for non-LV preflight.
- **Artifacts** – Session capsules under `tests/results/_agent/sessions/`, watcher telemetry
  (`tests/results/_agent/watcher` tree), and refreshed session-index JSON.
- **Action item** – Until the script exists, replicate the intended flow with `tools/Run-LocalBackbone.ps1` plus manual
  watcher dispatch; update this document once `tools/Start-IntegrationGated.ps1` is merged.
