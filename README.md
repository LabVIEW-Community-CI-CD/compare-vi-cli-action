<!-- markdownlint-disable-next-line MD041 -->
# Compare VI GitHub Action

[![Validate][badge-validate]][workflow-validate] [![Smoke][badge-smoke]][workflow-smoke]
[![Mock Tests][badge-mock]][workflow-test-mock] [![Docs][badge-docs]][environment-docs]

[badge-validate]: https://img.shields.io/github/actions/workflow/status/LabVIEW-Community-CI-CD/compare-vi-cli-action/validate.yml?label=Validate
[workflow-validate]: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml
[badge-smoke]: https://img.shields.io/github/actions/workflow/status/LabVIEW-Community-CI-CD/compare-vi-cli-action/smoke.yml?label=Smoke
[workflow-smoke]: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml
[badge-mock]: https://img.shields.io/github/actions/workflow/status/LabVIEW-Community-CI-CD/compare-vi-cli-action/test-mock.yml?label=Mock%20Tests
[workflow-test-mock]: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/test-mock.yml
[badge-docs]: https://img.shields.io/badge/docs-Environment%20Vars-6A5ACD
[environment-docs]: ./docs/ENVIRONMENT.md

## Overview

This composite action runs NI **LVCompare** to diff two LabVIEW virtual instruments (`.vi`). It supports PR checks,
scheduled verification, and loop-style benchmarking while emitting structured JSON artifacts and step summaries. The
action is validated against **LabVIEW 2025 Q3** on self-hosted Windows runners.

> **Breaking change (v0.5.0)** – canonical fixtures are now `VI1.vi` / `VI2.vi`. Legacy names > `Base.vi` / `Head.vi`
> are no longer published.

### Key capabilities

- Works on any self-hosted Windows runner with LVCompare installed.
- Exposes all LVCompare switches via the `lvCompareArgs` input.
- Produces machine-readable outputs (`compare-exec.json`, summaries, optional HTML).
- Bundles a watcher/telemetry toolkit to flag hangs, busy loops, and rogue processes.
- Includes an experimental loop mode for latency profiling.

## Quick start

```yaml
name: Compare LabVIEW VIs
on:
  pull_request:
    paths: ['**/*.vi']

jobs:
  compare:
    runs-on: [self-hosted, Windows, X64]
    steps:
      - uses: actions/checkout@v4
      - name: Run LVCompare
        uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@main
        with:
          base: fixtures/VI1.vi
          head: fixtures/VI2.vi
```

### Prerequisites

- LabVIEW (and LVCompare) installed on the runner (LabVIEW 2025 or later recommended). Default path: `C:\Program
  Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`. Bitness note: this canonical LVCompare path can
  operate as a launcher. To guarantee 64‑bit comparisons on x64 runners, provide a 64‑bit LabVIEW path using `-lvpath`
  or set `LABVIEW_EXE` to `C:\Program Files\National Instruments\LabVIEW 20xx\LabVIEW.exe`. The harness auto‑injects
  `-lvpath` when `LABVIEW_EXE` is set, so the compare executes in the 64‑bit LabVIEW environment even if the LVCompare
  stub itself is only a launcher.
- The repository checkout includes or generates the `.vi` files to compare.

### Optional: LabVIEW CLI compare mode

Set `LVCI_COMPARE_MODE=labview-cli` (and `LABVIEW_CLI_PATH` if the CLI isn't on the canonical path) to invoke
`LabVIEWCLI.exe CreateComparisonReport` instead of the standalone LVCompare executable. The action keeps the LVCompare
path as the required comparator; the CLI path is delivered via the new non-required `cli-compare.yml` workflow for
experimental runs. The CLI wrapper accepts `LVCI_CLI_FORMAT` (XML/HTML/TXT/DOCX), `LVCI_CLI_EXTRA_ARGS` for additional
flags (for example `--noDependencies`), and honors `LVCI_CLI_TIMEOUT_SECONDS` (default 120).

Use `LVCI_COMPARE_POLICY` to direct how automation chooses between LVCompare and LabVIEW CLI. The automation now
defaults to `cli-only` when the variable is unset so the compare flow remains headless. Set the variable explicitly if
you need a different behaviour.

- `cli-only` (default) – run via LabVIEW CLI and fail if CLI capture fails.
- `cli-first` – attempt CLI first, fall back to LVCompare on recoverable CLI failures (missing report, parse errors).
- `lv-first` – prefer LVCompare; only run CLI when explicitly requested via `LVCI_COMPARE_MODE`.
- `lv-only` – enforce LVCompare only.

When the base and head VIs share the same filename (typical commit-to-commit compares), automation continues to use the
CLI path (unless `lv-only` is explicitly configured) and skips warmup to avoid launching LabVIEW UI windows.

CLI-only quick start (64-bit Windows):

- On self-hosted runners with LabVIEW CLI installed, automation defaults the CLI path to `C:\Program Files
  (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe` when no overrides are set.
- To force CLI-only compare end-to-end (no LVCompare invocation):
  - Set `LVCI_COMPARE_MODE=labview-cli` and `LVCI_COMPARE_POLICY=cli-only`.
  - Run either wrapper:
    - Harness:

      ```powershell
      pwsh -File tools/TestStand-CompareHarness.ps1 -BaseVi VI1.vi -HeadVi VI2.vi -Warmup detect -RenderReport
      ```

      Use `-Warmup skip` to reuse an existing LabVIEW instance.
    - Wrapper:

      ```powershell
      pwsh -File tools/Invoke-LVCompare.ps1 -BaseVi VI1.vi -HeadVi VI2.vi -RenderReport
      ```

  - The capture (`lvcompare-capture.json`) includes an `environment.cli` block detailing the CLI path, version, parsed
  report type/path, status, and the final CLI message, alongside the command and arguments used for the
  `CreateComparisonReport` operation. When `-RenderReport` is set, the single-file HTML report is written alongside the
  capture.

Shim authors should follow the versioned pattern documented in
[`docs/LabVIEWCliShimPattern.md`](./docs/LabVIEWCliShimPattern.md) (`Close-LabVIEW.ps1` implements pattern v1.0). The
TestStand session index (`session-index.json`) now records the warmup mode, compare policy/mode, the resolved CLI
command, and the `environment.cli` metadata surfaced by the capture for downstream telemetry tools.

## Monitoring & telemetry

### Dev dashboard

```powershell
pwsh ./tools/Dev-Dashboard.ps1 `
  -Group pester-selfhosted `
  -ResultsRoot tests/results `
  -Html `
  -Json
```

This command renders a local snapshot of session-lock heartbeat age, queue wait trends, and DX reminders. Workflows call
`tools/Invoke-DevDashboard.ps1` to publish HTML/JSON artifacts.

### Live watcher

- `node tools/npm/run-script.mjs watch:pester` (warn 90 s, hang 180 s).
- `node tools/npm/run-script.mjs watch:pester:fast:exit` (warn 60 s, hang 120 s, exits on hang).
- `node tools/npm/run-script.mjs dev:watcher:ensure` / `status` / `stop` (persistent watcher lifecycle).
- `node tools/npm/run-script.mjs dev:watcher:trim` (rotates `watch.out` / `watch.err` when >5 MB or ~4,000 lines).
- `tools/Print-AgentHandoff.ps1 -AutoTrim` (prints summary and trims automatically when `needsTrim=true`; also writes a
  session capsule under `tests/results/_agent/sessions/` for the current workspace state).

Status JSON contains `state`, heartbeat freshness, and byte counters – ideal for hand-offs or CI summaries.

#### Watch orchestrated run (Docker)

Use the token/REST-capable watcher to inspect the orchestrated run’s dispatcher logs and artifacts without opening the
web UI:

```powershell
pwsh -File tools/Watch-InDocker.ps1 -RunId <id> -Repo LabVIEW-Community-CI-CD/compare-vi-cli-action
```

Tips:

- Run `pwsh -File tools/Get-StandingPriority.ps1 -Plain` to display the current standing-priority issue number and
  title.
- Set `GH_TOKEN` or `GITHUB_TOKEN` in your environment (admin token recommended). The watcher also falls back to
  `C:\github_token.txt` when the env vars are unset.
- VS Code: use "Integration (Standing Priority): Auto Push + Start + Watch" under Run Task to push, dispatch, and stream
  in one step. Additional one-click tasks now ship in `.vscode/tasks.json`:
  - `Build CompareVI CLI (Release)` compiles `src/CompareVi.Tools.Cli` in Release before any parsing work.
  - `Parse CLI Compare Outcome (.NET)` depends on the build task and writes `tests/results/compare-cli/compare-
    outcome.json`.
  - `Integration (Standing Priority): Watch existing run` attaches the Docker watcher when a run is already in flight.
  - `Run Non-LV Checks (Docker)` shells into `tools/Run-NonLVChecksInDocker.ps1` for actionlint/markdownlint/docs drift.
  - Recommended extensions (PowerShell, C#, GitHub Actions, markdownlint, Docker) are declared in
    `.vscode/extensions.json`.
  - Local validation quick reference (see below) keeps local runs aligned with CI stages.
- Prefer the REST watcher for GitHub status: `node tools/npm/run-script.mjs ci:watch:rest -- --run-id <id>` streams job
  conclusions without relying on the `gh` CLI. Passing `--branch <name>` auto-selects the latest run. A VS Code task
  named “CI Watch (REST)” prompts for the run id.
- Repeated 404s or other API errors cause the watcher to exit with `conclusion: watcher-error` after the built-in grace
  window (90s for “run not found”, 120s for other failures) while still writing `watcher-rest.json` to keep telemetry
  flowing. Direct rate-limit responses abort immediately with guidance to authenticate via `GH_TOKEN`/`GITHUB_TOKEN` or
  wait for the reset window.
- The REST watcher writes `watcher-rest.json` into the job’s results directory; `tools/Update-SessionIndexWatcher.ps1`
  merges the data into `session-index.json` so CI telemetry reflects the final GitHub status alongside Pester results.
- The watcher prunes old run directories (`.tmp/watch-run`) automatically and warns if run/dispatcher status stalls
  longer than the configured window (default 10 minutes). When consecutive dispatcher logs hash to the same digest, it
  flags a possible repeated failure.

#### Local validation quick reference

- **Run PrePush Checks** (`pwsh -File tools/PrePush-Checks.ps1` / “Run PrePush
  Checks”): mirrors the Validate job (lint, compare-report manifest, rerun hint
  helper).
- **Run Pester Tests (Unit)** (`pwsh ./Invoke-PesterTests.ps1` / “Run Pester
  Tests (Unit)”): executes the Validate unit suites.
- **Run Pester Tests (Integration)** (`pwsh ./Invoke-PesterTests.ps1 -IntegrationMode
  include` / “Run Pester Tests (Integration)”): runs integration coverage prior
  to orchestrated dispatch.
- **Build Tools Image (Docker)**: `tools/Build-ToolsImage.ps1 -Tag
  comparevi-tools:local` prepares a unified container with dotnet, Node,
  Python, PowerShell, and actionlint.
- **Run Non-LV Checks (Tools Image)**: `tools/Run-NonLVChecksInDocker.ps1
  -ToolsImageTag comparevi-tools:local -UseToolsImage` runs actionlint,
  markdownlint, docs drift detection, and builds the CLI (output
  `dist/comparevi-cli`) inside the tools container.
- **Run Non-LV Checks (Docker)**: `tools/Run-NonLVChecksInDocker.ps1` executes
  the same checks via per-tool images (fallback path).
- **Integration (Standing Priority): Auto Push + Start + Watch**:
  `tools/Start-IntegrationGated.ps1 -AutoPush -Start -Watch` aligns with the
  `ci-orchestrated` standing-priority dispatcher + watcher flow.

These entry points exercise the same scripts CI relies on. Run them locally before pushing so Validate and ci-
orchestrated stay green.

#### Start integration (gated)

The one-button task "Integration (Standing Priority): Auto Push + Start + Watch" deterministically starts an
orchestrated run only after selecting an allowed GitHub issue. The allow-list lives in `tools/policy/allowed-
integration-issues.json` (seeded with the standing-priority issue and `#118`). The task:

1. Auto-detects an admin token (`GH_TOKEN`, `GITHUB_TOKEN`, or `C:\github_token.txt`).
2. Pushes the current branch using that token (no manual git needed).
3. Dispatches `ci-orchestrated.yml` via GitHub CLI/REST.
4. Launches the Docker watcher so the run is streamed immediately in the terminal.

Prompts:

- Issue: allowed issue number.
- Strategy: `single` or `matrix`.
- Include integration: `true`/`false`.
- Ref: `develop` (default) or current branch.

#### Deterministic two-phase pipeline

`ci-orchestrated.yml` executes as a deterministic two-phase flow:

1. `phase-vars` (self-hosted Windows) writes `tests/results/_phase/vars.json` with a digest (`tools/Write-
   PhaseVars.ps1`).
2. `pester-unit` consumes the manifest and runs Unit-only tests with `DETERMINISTIC=1` (no retries or cleanup).
3. `pester-integration` runs Integration-only tests (gated on unit success and the include flag) using
   `-OnlyIntegration`.

The manifest is validated with `tools/Validate-PhaseVars.ps1` and exported through `tools/Export-PhaseVars.ps1`. Each
phase uploads dedicated artifacts (`pester-unit-*`, `pester-integration-*`, `invoker-boot-*`).

#### Docker-based lint/validation

Use `tools/Run-NonLVChecksInDocker.ps1` to rebuild container tooling and re-run lint/docs/workflow checks:

```powershell
pwsh -File tools/Run-NonLVChecksInDocker.ps1
```

The script pulls pinned images (actionlint, node, PowerShell, python) and forwards only approved env vars (compatible
with `DETERMINISTIC=1`). Add switches such as `-SkipDocs`/`-SkipWorkflow`/ `-SkipMarkdown` to focus on specific checks,
then rerun the VS Code task to verify fixes.

## Bundled workflows

- **Validate** - end-to-end self-hosted validation (fixtures, LVCompare, Pester suites).
- **Smoke** - minimal regression guard for documentation-only changes.
- **Fixture Drift** - verifies fixture manifests and retains comparison evidence.
- **VI Binary Gate** - ensures LabVIEW binaries remain normalized.
- **Markdownlint** - runs `node tools/npm/run-script.mjs lint:md:changed` with the trimmed configuration below.
- **UI/Dispatcher Smoke** - non-required quick pass of dispatcher/UI paths without invoking LVCompare (label `ui-smoke`
  or manual dispatch).
- **LabVIEW CLI Compare** - non-required experiment that invokes LabVIEW CLI `CreateComparisonReport` with canonical
  fixtures (requires LabVIEW 2025+).

Explore `.github/workflows` for matrices, inputs, and dispatch helpers.

## Markdown lint

`markdownlint` is configured to allow up to 120 columns (tables, code fences, headings excluded) and to downgrade MD041
while legacy docs are cleaned. Generated artifacts are ignored via `.markdownlintignore`.

Lint changed files locally:

```powershell
node tools/npm/run-script.mjs lint:md:changed
```

## Documentation map

| Topic | Location |
| ----- | -------- |
| Action usage | `docs/USAGE_GUIDE.md` |
| Fixture drift | `docs/FIXTURE_DRIFT.md` |
| Loop mode | `docs/COMPARE_LOOP_MODULE.md` |
| Preflight validator & UI smoke | See README (this section) and `.github/workflows/ui-smoke.yml` |
| Integration runbook | `docs/INTEGRATION_RUNBOOK.md` |
| Troubleshooting | `docs/TROUBLESHOOTING.md` |
| Traceability (requirements ↔ tests) | `docs/TRACEABILITY_GUIDE.md` |

## Contributing

1. Branch from `develop`, run `npm ci`.
2. Execute tests (`./Invoke-PesterTests.ps1` or watcher-assisted workflows).
3. Lint (`node tools/npm/run-script.mjs lint:md:changed`, `tools/Check-ClangFormat.ps1` if relevant).
4. Submit a PR referencing the standing-priority issue and include rationale plus artifacts.

Follow `AGENTS.md` for coding etiquette and keep CI deterministic. Large workflow updates should note affected jobs and
link to supporting ADRs.

### Local validation matrix (pre-push checklist)

Run the commands below (or invoke the matching VS Code task) before pushing. Each entry calls the same automation that
our workflows execute, so local runs mirror CI behaviour.

- **Run PrePush Checks** (`pwsh -File tools/PrePush-Checks.ps1` / “Run PrePush
  Checks”): mirrors `validate.yml › lint` and runs actionlint, markdownlint,
  the tracked-artifact guard, rerun-hint helper, and watcher schema validation.
- **Run Pester Tests (Unit)** (`pwsh ./Invoke-PesterTests.ps1` / “Run Pester
  Tests (Unit)”): mirrors the unit consumers in `validate.yml` for fast
  feedback before orchestrated dispatch.
- **Run Pester Tests (Integration)** (`pwsh ./Invoke-PesterTests.ps1
  -IntegrationMode include` / “Run Pester Tests (Integration)”): mirrors the
  integration phase in `ci-orchestrated.yml` and smoke stages in
  `validate.yml`; requires LVCompare.
- **Run Non-LV Checks (Tools Image)**:
  `tools/Run-NonLVChecksInDocker.ps1 -ToolsImageTag comparevi-tools:local
  -UseToolsImage` mirrors `validate.yml › cli-smoke` using the consolidated
  tools image so actionlint/markdownlint/docs drift checks match the smoke
  environment while building the CLI artifact.
- **Run Non-LV Checks (Docker)**: `tools/Run-NonLVChecksInDocker.ps1` mirrors
  the same job using per-tool containers when the unified image is unavailable.
- **Integration (Standing Priority): Auto Push + Start + Watch**:
  `tools/Start-IntegrationGated.ps1 -AutoPush -Start -Watch` mirrors the
  `ci-orchestrated` standing-priority dispatcher + watcher; it pushes with the
  admin token, resolves issue [#127](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/127),
  dispatches, then streams logs via the Docker watcher.

Keeping these green locally prevents surprises when Validate or the orchestrated pipeline runs in CI.

#### Multi-plane hook helpers

#### Standing priority helpers

- `node tools/npm/run-script.mjs priority:bootstrap` — run hook preflight/parity (optional via `-- -VerboseHooks`) and
  refresh the standing-priority snapshot/router.
- `node tools/npm/run-script.mjs priority:handoff` — import the latest handoff summaries into the current PowerShell
  session (globals such as `$StandingPrioritySnapshot` and `$StandingPriorityRouter`).
- `node tools/npm/run-script.mjs priority:handoff-tests` — execute the priority/hooks/semver checks and write
  `tests/results/_agent/handoff/test-summary.json` for later review.
- `node tools/npm/run-script.mjs priority:release` — simulate the release path from the router; add `-- -Execute` to run
  `Branch-Orchestrator.ps1 -Execute` instead of the default dry-run.
- `node tools/npm/run-script.mjs handoff:schema` - validate the stored hook handoff summary against
  `docs/schemas/handoff-hook-summary-v1.schema.json`.
- `node tools/npm/run-script.mjs handoff:release-schema` - validate the release summary
  (`tests/results/_agent/handoff/release-summary.json`) against `docs/schemas/handoff-release-v1.schema.json`.
- `node tools/npm/run-script.mjs handoff:session-schema` - validate stored session capsules
  (`tests/results/_agent/sessions/*.json`) against `docs/schemas/handoff-session-v1.schema.json`.
- `node tools/npm/run-script.mjs semver:check` — run the SemVer validator (`tools/priority/validate-semver.mjs`) against
  the current package version.


- `node tools/npm/run-script.mjs hooks:plane` — prints the detected plane (for example `windows-pwsh`, `linux-wsl`,
  `github-ubuntu`) and the active enforcement mode.
- `node tools/npm/run-script.mjs hooks:preflight` — verifies Node/PowerShell availability for the current plane and
  warns if a dependency is missing.
- `node tools/npm/run-script.mjs hooks:multi` — runs both the shell and PowerShell wrappers, publishes labelled
  summaries (`tests/results/_hooks/pre-commit.shell.json`, etc.), and fails when the JSON differs.
- `node tools/npm/run-script.mjs hooks:schema` — validates all hook summaries against `docs/schemas/hooks-
  summary-v1.schema.json`.

Tune behaviour with `HOOKS_ENFORCE=fail|warn|off` (default: `fail` in CI, `warn` locally). Use `HOOKS_PWSH` or
`HOOKS_NODE` to point at custom executables when bouncing between planes.

## Support & feedback

- File issues: <https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues>
- Contact NI for LabVIEW licensing questions.
- For agent coordination, follow the steps in `AGENT_HANDOFF.txt`.

### VS Code extension (experimental)

The N-CLI companion (under `vscode/comparevi-helper`) centralises CompareVI and other CLI helpers in VS Code. The
CompareVI provider mirrors the CLI workflows from this repository—manual compares, commit compares, preset CRUD,
artifact thumbnails—while adding health checks and telemetry. A stub g-cli provider exercises the provider registry and
warns when g-cli is not installed yet.

Key features:

- Provider switcher with metadata (docs links, health status, disabled reason).
- LabVIEW health checks (LabVIEW.exe + LabVIEW.ini snapshotting) and g-cli executable detection.
- CLI preview commands (copy/current/last, open in terminal) and quick controls for commit ref swaps, presets, and
  artifact thumbnails.
- Local NDJSON telemetry written to `tests/results/telemetry/` when `comparevi.telemetryEnabled` is enabled.

For local development:

1. Run `npm install` inside `vscode/comparevi-helper`.
2. From VS Code, run **Debug: Start Debugging** on the extension to launch a dev host.
3. `node tools/npm/run-script.mjs test:unit` and `node tools/npm/run-script.mjs test:ext` validate provider registry
   behaviour, telemetry, multi-root flows, and UI wiring.

Packaging notes:

1. Development: run `npm install` then press `F5` (Debug: Start Debugging) from VS Code to side-load the extension.
2. Optional VSIX: install `vsce` locally and run `node tools/npm/run-script.mjs --prefix vscode/comparevi-helper
   package`; install the resulting VSIX via “Extensions: Install from VSIX...” if you prefer a self-contained bundle
   instead of running the debug host.


## Documentation Manifest

- Canonical manifest: `docs/documentation-manifest.json`
  - Groups every tracked Markdown file into authoritative, draft, reference, or generated sets.
  - Patterns are evaluated relative to the repository root.
- Validate updates before committing: `node tools/npm/run-script.mjs docs:manifest:validate`
- Promote drafts by migrating files from `issues-drafts/` into the `docs/` tree and updating the manifest entry status.


## CLI Distribution

The repository ships a cross-platform CLI (comparevi-cli) used by workflows and local tools. Use the publish helper to
build per-RID archives and checksums for distribution.

- Build artifacts
  - `node tools/npm/run-script.mjs publish:cli` (or `pwsh -File tools/Publish-Cli.ps1`)
  - Produces framework-dependent and self-contained archives under `artifacts/cli/`:
    - Windows: `.zip` files
    - Linux/macOS: `.tar.gz` files
  - A consolidated `SHA256SUMS.txt` is emitted alongside the archives.

- Verify checksums
  - PowerShell: `Get-FileHash -Algorithm SHA256 artifacts/cli/<file> | Format-List`
  - Bash: `sha256sum artifacts/cli/<file>`

- Extract and run
  - Windows: unzip and run `comparevi-cli.exe`
  - Linux/macOS: `tar -xzf <file>.tar.gz`; then run `./comparevi-cli`
    - Note: when archives are created on Windows runners, execute bits may not be preserved in tarballs. If the binary
      isn't executable after extract, run `chmod +x ./comparevi-cli`.

- Quick smoke
  - `./comparevi-cli version`
- `./comparevi-cli tokenize --input 'foo -x=1 "bar baz"'`
- `./comparevi-cli quote --path 'C:/Program Files/National Instruments/LabVIEW 2025/LabVIEW.exe'`
- `./comparevi-cli procs`
- `./comparevi-cli operations`
- `./comparevi-cli operations --names-only`
- `./comparevi-cli providers`
- `./comparevi-cli providers --names-only`
- `./comparevi-cli providers --name labviewcli`

