<!-- markdownlint-disable-next-line MD041 -->
# Compare VI GitHub Action

[![Validate][badge-validate]][workflow-validate]
[![Smoke][badge-smoke]][workflow-smoke]
[![Mock Tests][badge-mock]][workflow-test-mock]
[![Docs][badge-docs]][environment-docs]

[badge-validate]: https://img.shields.io/github/actions/workflow/status/LabVIEW-Community-CI-CD/compare-vi-cli-action/validate.yml?label=Validate
[workflow-validate]: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml
[badge-smoke]: https://img.shields.io/github/actions/workflow/status/LabVIEW-Community-CI-CD/compare-vi-cli-action/smoke.yml?label=Smoke
[workflow-smoke]: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml
[badge-mock]: https://img.shields.io/github/actions/workflow/status/LabVIEW-Community-CI-CD/compare-vi-cli-action/test-mock.yml?label=Mock%20Tests
[workflow-test-mock]: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/test-mock.yml
[badge-docs]: https://img.shields.io/badge/docs-Environment%20Vars-6A5ACD
[environment-docs]: ./docs/ENVIRONMENT.md

## Overview

This composite action runs NI **LVCompare** to diff two LabVIEW virtual instruments (`.vi`). It
supports PR checks, scheduled verification, and loop-style benchmarking while emitting
structured JSON artifacts and step summaries. The action is validated against **LabVIEW 2025
Q3** on self-hosted Windows runners.

> **Breaking change (v0.5.0)** – canonical fixtures are now `VI1.vi` / `VI2.vi`. Legacy names
> `Base.vi` / `Head.vi` are no longer published.

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

- LabVIEW (and LVCompare) installed on the runner (LabVIEW 2025 or later recommended). Default path:
  `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`.
  Bitness note: this canonical LVCompare path can operate as a launcher. To guarantee 64‑bit
  comparisons on x64 runners, provide a 64‑bit LabVIEW path using `-lvpath` or set
  `LABVIEW_EXE` to `C:\Program Files\National Instruments\LabVIEW 20xx\LabVIEW.exe`.
  The harness auto‑injects `-lvpath` when `LABVIEW_EXE` is set, so the compare executes in the
  64‑bit LabVIEW environment even if the LVCompare stub itself is only a launcher.
- The repository checkout includes or generates the `.vi` files to compare.

### Optional: LabVIEW CLI compare mode

Set `LVCI_COMPARE_MODE=labview-cli` (and `LABVIEW_CLI_PATH` if the CLI isn't on the canonical path) to invoke
`LabVIEWCLI.exe CreateComparisonReport` instead of the standalone LVCompare executable. The action keeps the
LVCompare path as the required comparator; the CLI path is delivered via the new non-required
`cli-compare.yml` workflow for experimental runs. The CLI wrapper accepts `LVCI_CLI_FORMAT` (XML/HTML/TXT/DOCX),
`LVCI_CLI_EXTRA_ARGS` for additional flags (for example `--noDependencies`), and honors
`LVCI_CLI_TIMEOUT_SECONDS` (default 120).

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

- On self-hosted runners with LabVIEW CLI installed, automation defaults the CLI path to
  `C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe` when no
  overrides are set.
- To force CLI-only compare end-to-end (no LVCompare invocation):
  - Set `LVCI_COMPARE_MODE=labview-cli` and `LVCI_COMPARE_POLICY=cli-only`.
  - Run either wrapper:
    - Harness: `pwsh -File tools/TestStand-CompareHarness.ps1 -BaseVi VI1.vi -HeadVi VI2.vi -Warmup detect -RenderReport` (`-Warmup skip` reuses an existing LabVIEW instance)
    - Wrapper: `pwsh -File tools/Invoke-LVCompare.ps1 -BaseVi VI1.vi -HeadVi VI2.vi -RenderReport`
- The capture (`lvcompare-capture.json`) includes an `environment.cli` block detailing the CLI
  path, version, parsed report type/path, status, and the final CLI message, alongside the command
  and arguments used for the `CreateComparisonReport` operation. When `-RenderReport` is set, the
  single-file HTML report is written alongside the capture.

Shim authors should follow the versioned pattern documented in [`docs/LabVIEWCliShimPattern.md`](./docs/LabVIEWCliShimPattern.md)
(`Close-LabVIEW.ps1` implements pattern v1.0).
The TestStand session index (`session-index.json`) now records the warmup mode, compare policy/mode,
the resolved CLI command, and the `environment.cli` metadata surfaced by the capture for downstream
telemetry tools.

## Monitoring & telemetry

### Dev dashboard

```powershell
pwsh ./tools/Dev-Dashboard.ps1 `
  -Group pester-selfhosted `
  -ResultsRoot tests/results `
  -Html `
  -Json
```

This command renders a local snapshot of session-lock heartbeat age, queue wait trends, and
DX reminders. Workflows call `tools/Invoke-DevDashboard.ps1` to publish HTML/JSON artifacts.

### Live watcher

- `npm run watch:pester` (warn 90 s, hang 180 s).
- `npm run watch:pester:fast:exit` (warn 60 s, hang 120 s, exits on hang).
- `npm run dev:watcher:ensure` / `status` / `stop` (persistent watcher lifecycle).
- `npm run dev:watcher:trim` (rotates `watch.out` / `watch.err` when >5 MB or ~4,000 lines).
- `tools/Print-AgentHandoff.ps1 -AutoTrim` (prints summary and trims automatically when
  `needsTrim=true`; also writes a session capsule under
  `tests/results/_agent/sessions/` for the current workspace state).

Status JSON contains `state`, heartbeat freshness, and byte counters – ideal for hand-offs or
CI summaries.

#### Watch orchestrated run (Docker)

Use the token/REST-capable watcher to inspect the orchestrated run’s dispatcher logs and
artifacts without opening the web UI:

```powershell
pwsh -File tools/Watch-InDocker.ps1 -RunId <id> -Repo LabVIEW-Community-CI-CD/compare-vi-cli-action
```

Tips:

- Run `pwsh -File tools/Get-StandingPriority.ps1 -Plain` to display the current standing-priority
  issue number and title.
- Set `GH_TOKEN` or `GITHUB_TOKEN` in your environment (admin token recommended). The watcher also
  falls back to `C:\github_token.txt` when the env vars are unset.
- VS Code: use "Integration (Standing Priority): Auto Push + Start + Watch" under Run Task to push, dispatch, and
  stream in one step. Additional one-click tasks now ship in `.vscode/tasks.json`:
  - `Build CompareVI CLI (Release)` compiles `src/CompareVi.Tools.Cli` in Release before any parsing work.
  - `Parse CLI Compare Outcome (.NET)` depends on the build task and writes `tests/results/compare-cli/compare-outcome.json`.
  - `Integration (Standing Priority): Watch existing run` attaches the Docker watcher when a run is already in flight.
  - `Run Non-LV Checks (Docker)` shells into `tools/Run-NonLVChecksInDocker.ps1` for actionlint/markdownlint/docs drift.
  - Recommended extensions (PowerShell, C#, GitHub Actions, markdownlint, Docker) are declared in `.vscode/extensions.json`.
  - Local validation matrix (see below) keeps local runs aligned with CI stages.
- Prefer the REST watcher for GitHub status: `npm run ci:watch:rest -- --run-id <id>` streams job conclusions without relying on the
  `gh` CLI. Passing `--branch <name>` auto-selects the latest run. A VS Code task named “CI Watch (REST)” prompts for the run id.
- Repeated 404s or other API errors cause the watcher to exit with `conclusion: watcher-error` after the built-in grace window
  (90s for “run not found”, 120s for other failures) while still writing `watcher-rest.json` to keep telemetry flowing.
- The REST watcher writes `watcher-rest.json` into the job’s results directory; `tools/Update-SessionIndexWatcher.ps1` merges the data
  into `session-index.json` so CI telemetry reflects the final GitHub status alongside Pester results.
- The watcher prunes old run directories (`.tmp/watch-run`) automatically and warns if
  run/dispatcher status stalls longer than the configured window (default 10 minutes). When
  consecutive dispatcher logs hash to the same digest, it flags a possible repeated failure.

#### Local validation matrix

| Command / Run Task | Script invoked | Mirrors CI job(s) |
| --- | --- | --- |
| `pwsh -File tools/PrePush-Checks.ps1` / “Run PrePush Checks” | `tools/PrePush-Checks.ps1` | Validate: lint, compare-report manifest, rerun hint helper |
| `pwsh ./Invoke-PesterTests.ps1` / “Run Pester Tests (Unit)” | `Invoke-PesterTests.ps1` | Validate: unit suites |
| `pwsh ./Invoke-PesterTests.ps1 -IntegrationMode include` / “Run Pester Tests (Integration)” | `Invoke-PesterTests.ps1` with integration flag | Validate: integration coverage leading into orchestrated phase |
| “Build Tools Image (Docker)” | `tools/Build-ToolsImage.ps1 -Tag comparevi-tools:local` | Prepares a unified container with all non-LV deps (dotnet/Node/Python/PS/actionlint) |
| “Run Non-LV Checks (Tools Image)” | `tools/Run-NonLVChecksInDocker.ps1 -ToolsImageTag comparevi-tools:local -UseToolsImage` | Validate: run actionlint/markdownlint/docs drift + build CLI (output `dist/comparevi-cli`) in one container |
| “Run Non-LV Checks (Docker)” | `tools/Run-NonLVChecksInDocker.ps1` | Validate: same checks using per-tool images (fallback path) |
| “Integration (Standing Priority): Auto Push + Start + Watch” | `tools/Start-IntegrationGated.ps1 -AutoPush -Start -Watch` | ci-orchestrated: standing-priority dispatcher + watcher |

These entry points exercise the same scripts CI relies on. Run them locally before pushing so Validate and ci-orchestrated stay green.

#### Start integration (gated)

The one-button task "Integration (Standing Priority): Auto Push + Start + Watch" deterministically starts an
orchestrated run only after selecting an allowed GitHub issue. The allow-list lives in
`tools/policy/allowed-integration-issues.json` (seeded with the standing-priority issue and `#118`). The task:

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

1. `phase-vars` (self-hosted Windows) writes `tests/results/_phase/vars.json` with a digest
   (`tools/Write-PhaseVars.ps1`).
2. `pester-unit` consumes the manifest and runs Unit-only tests with `DETERMINISTIC=1` (no retries
   or cleanup).
3. `pester-integration` runs Integration-only tests (gated on unit success and the include flag)
   using `-OnlyIntegration`.

The manifest is validated with `tools/Validate-PhaseVars.ps1` and exported through
`tools/Export-PhaseVars.ps1`. Each phase uploads dedicated artifacts (`pester-unit-*`,
`pester-integration-*`, `invoker-boot-*`).

#### Docker-based lint/validation

Use `tools/Run-NonLVChecksInDocker.ps1` to rebuild container tooling and re-run lint/docs/workflow checks:

```powershell
pwsh -File tools/Run-NonLVChecksInDocker.ps1
```

The script pulls pinned images (actionlint, node, PowerShell, python) and forwards only approved env
vars (compatible with `DETERMINISTIC=1`). Add switches such as `-SkipDocs`/`-SkipWorkflow`/
`-SkipMarkdown` to focus on specific checks, then rerun the VS Code task to verify fixes.

## Bundled workflows

- **Validate** - end-to-end self-hosted validation (fixtures, LVCompare, Pester suites).
- **Smoke** - minimal regression guard for documentation-only changes.
- **Fixture Drift** - verifies fixture manifests and retains comparison evidence.
- **VI Binary Gate** - ensures LabVIEW binaries remain normalized.
- **Markdownlint** - runs `npm run lint:md:changed` with the trimmed configuration below.
- **UI/Dispatcher Smoke** - non-required quick pass of dispatcher/UI paths without invoking LVCompare (label `ui-smoke` or manual dispatch).
- **LabVIEW CLI Compare** - non-required experiment that invokes LabVIEW CLI `CreateComparisonReport` with canonical fixtures (requires LabVIEW 2025+).

Explore `.github/workflows` for matrices, inputs, and dispatch helpers.

## Markdown lint

`markdownlint` is configured to allow up to 120 columns (tables, code fences, headings
excluded) and to downgrade MD041 while legacy docs are cleaned. Generated artifacts are
ignored via `.markdownlintignore`.

Lint changed files locally:

```powershell
npm run lint:md:changed
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
3. Lint (`npm run lint:md:changed`, `tools/Check-ClangFormat.ps1` if relevant).
4. Submit a PR referencing the standing-priority issue and include rationale plus artifacts.

Follow `AGENTS.md` for coding etiquette and keep CI deterministic. Large workflow updates
should note affected jobs and link to supporting ADRs.

### Local validation matrix

Run the commands below (or invoke the matching VS Code task) before pushing. Each entry calls the same automation that our workflows execute, so local runs mirror CI behaviour.

| Command / Run Task | Script invoked | Mirrors CI job(s) | Notes |
| --- | --- | --- | --- |
| `pwsh -File tools/PrePush-Checks.ps1` / “Run PrePush Checks” | `tools/PrePush-Checks.ps1` | `validate.yml › lint` | Runs actionlint, markdownlint, tracked-artifact guard, rerun-hint helper, watcher schema validation. |
| `pwsh ./Invoke-PesterTests.ps1` / “Run Pester Tests (Unit)” | `Invoke-PesterTests.ps1` | Unit consumers in `validate.yml` | Fast feedback on unit suites before dispatching orchestrated runs. |
| `pwsh ./Invoke-PesterTests.ps1 -IntegrationMode include` / “Run Pester Tests (Integration)” | `Invoke-PesterTests.ps1 -IntegrationMode include` | Integration phase in `ci-orchestrated.yml` and smoke stages in `validate.yml` | Requires LVCompare; runs the same categories the orchestrated pipeline executes. |
| “Run Non-LV Checks (Tools Image)” | `tools/Run-NonLVChecksInDocker.ps1 -ToolsImageTag comparevi-tools:local -UseToolsImage` | `validate.yml › cli-smoke` non-LV preflight | Uses the consolidated tools image so actionlint/markdownlint/docs drift checks match the smoke job environment. |
| “Run Non-LV Checks (Docker)” | `tools/Run-NonLVChecksInDocker.ps1` | `validate.yml › cli-smoke` fallback path | Falls back to per-tool containers when the unified image is unavailable. |
| “Integration (Standing Priority): Auto Push + Start + Watch” | `tools/Start-IntegrationGated.ps1 -AutoPush -Start -Watch` | `ci-orchestrated.yml` standing-priority dispatcher + watcher | Pushes with the admin token, resolves issue [#127](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/127), dispatches, then streams logs via Docker watcher. |

Keeping these green locally prevents surprises when Validate or the orchestrated pipeline runs in CI.

#### Multi-plane hook helpers

#### Standing priority helpers

- `npm run priority:bootstrap` — run hook preflight/parity (optional via `-- -VerboseHooks`) and refresh the standing-priority snapshot/router.
- `npm run priority:handoff` — import the latest handoff summaries into the current PowerShell session (globals such as `$StandingPrioritySnapshot` and `$StandingPriorityRouter`).
- `npm run priority:handoff-tests` — execute the priority/hooks/semver checks and write `tests/results/_agent/handoff/test-summary.json` for later review.
- `npm run priority:release` — simulate the release path from the router; add `-- -Execute` to run `Branch-Orchestrator.ps1 -Execute` instead of the default dry-run.
- `npm run handoff:schema` - validate the stored hook handoff summary against `docs/schemas/handoff-hook-summary-v1.schema.json`.
- `npm run handoff:release-schema` - validate the release summary (`tests/results/_agent/handoff/release-summary.json`) against `docs/schemas/handoff-release-v1.schema.json`.
- `npm run handoff:session-schema` - validate stored session capsules (`tests/results/_agent/sessions/*.json`) against `docs/schemas/handoff-session-v1.schema.json`.
- `npm run semver:check` — run the SemVer validator (`tools/priority/validate-semver.mjs`) against the current package version.


- `npm run hooks:plane` — prints the detected plane (for example `windows-pwsh`, `linux-wsl`, `github-ubuntu`) and the active enforcement mode.
- `npm run hooks:preflight` — verifies Node/PowerShell availability for the current plane and warns if a dependency is missing.
- `npm run hooks:multi` — runs both the shell and PowerShell wrappers, publishes labelled summaries (`tests/results/_hooks/pre-commit.shell.json`, etc.), and fails when the JSON differs.
- `npm run hooks:schema` — validates all hook summaries against `docs/schemas/hooks-summary-v1.schema.json`.

Tune behaviour with `HOOKS_ENFORCE=fail|warn|off` (default: `fail` in CI, `warn` locally). Use `HOOKS_PWSH` or `HOOKS_NODE` to point at custom executables when bouncing between planes.

## Support & feedback

- File issues: <https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues>
- Contact NI for LabVIEW licensing questions.
- For agent coordination, follow the steps in `AGENT_HANDOFF.txt`.

#### VS Code extension (experimental)

A thin VS Code extension lives in `tools/vscode/comparevi-extension`. It exposes commands that wrap the tasks above:
- `CompareVI: Build & Parse CLI`
- `CompareVI: Start Standing Priority Run`
- `CompareVI: Watch Standing Priority Run`
- `CompareVI: Open Artifact`
- `CompareVI: Show Artifact Summary`

For local development:
1. Run `npm install` inside `tools/vscode/comparevi-extension`.
2. From VS Code, run **Debug: Start Debugging** on the extension to launch a dev host.
3. Commands shell out to the tasks in `.vscode/tasks.json`, so behaviour stays aligned with local scripts/CI. `npm run compile` builds TypeScript, and `npm test` exercises a smoke test via `@vscode/test-electron`.

The extension also contributes a **CompareVI Artifacts** tree in the Explorer view. It lists `tests/results/compare-cli/queue-summary.json`, `compare-outcome.json`, the session index, and phase manifest when available. Use the context menu (or the summary command) to view an HTML summary of JSON artifacts alongside the raw file.

Packaging notes:

1. Development: run `npm install` then press `F5` (Debug: Start Debugging) from VS Code to side-load the extension.
2. Compilation: run `npm run compile` prior to packaging.
3. Optional VSIX: install `vsce` locally and run `npx vsce package` inside `tools/vscode/comparevi-extension`; install the resulting VSIX via “Extensions: Install from VSIX...” if you prefer a self-contained bundle instead of running the debug host.
pm test exercises the registration smoke test via @vscode/test-electron.


## Documentation Manifest

- Canonical manifest: `docs/documentation-manifest.json`
  - Groups every tracked Markdown file into authoritative, draft, reference, or generated sets.
  - Patterns are evaluated relative to the repository root.
- Validate updates before committing: `npm run docs:manifest:validate`
- Promote drafts by migrating files from `issues-drafts/` into the `docs/` tree and updating the manifest entry status.


## CLI Distribution

The repository ships a cross-platform CLI (comparevi-cli) used by workflows and local tools. Use the
publish helper to build per-RID archives and checksums for distribution.

- Build artifacts
  - `npm run publish:cli` (or `pwsh -File tools/Publish-Cli.ps1`)
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

