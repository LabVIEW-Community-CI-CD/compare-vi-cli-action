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

- LabVIEW (and LVCompare) installed on the runner. Default path:
  `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`.
- The repository checkout includes or generates the `.vi` files to compare.

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
  `needsTrim=true`).

Status JSON contains `state`, heartbeat freshness, and byte counters – ideal for hand-offs or
CI summaries.

#### Watch orchestrated run (Docker)

Use the token/REST-capable watcher to inspect the orchestrated run’s dispatcher logs and
artifacts without opening the web UI:

```
pwsh -File tools/Watch-InDocker.ps1 -RunId <id> -Repo LabVIEW-Community-CI-CD/compare-vi-cli-action
```

Tips:
- Set `GH_TOKEN` or `GITHUB_TOKEN` in your environment (admin token recommended). The watcher also falls back to `C:\github_token.txt` when the env vars are unset.
- VS Code: use “Integration (#88): Auto Push + Start + Watch” under Run Task to push, dispatch, and stream in one step.
- The watcher prunes old run directories (`.tmp/watch-run`) automatically and warns if run/dispatcher status stalls longer than the configured window (default 10 minutes). When consecutive dispatcher logs hash to the same digest, it flags a possible repeated failure.

#### Start integration (gated)

The one-button task “Integration (#88): Auto Push + Start + Watch” deterministically starts an orchestrated run only after selecting an allowed GitHub issue. The allow-list lives in `tools/policy/allowed-integration-issues.json` (default: `#88`, `#118`). The task:

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

1. `phase-vars` (self-hosted Windows) writes `tests/results/_phase/vars.json` with a digest (`tools/Write-PhaseVars.ps1`).
2. `pester-unit` consumes the manifest and runs Unit-only tests with `DETERMINISTIC=1` (no retries or cleanup).
3. `pester-integration` runs Integration-only tests (gated on unit success and the include flag) using `-OnlyIntegration`.

The manifest is validated with `tools/Validate-PhaseVars.ps1` and exported through `tools/Export-PhaseVars.ps1`. Each phase uploads dedicated artifacts (`pester-unit-*`, `pester-integration-*`, `invoker-boot-*`).

#### Docker-based lint/validation

Use `tools/Run-NonLVChecksInDocker.ps1` to rebuild container tooling and re-run lint/docs/workflow checks:

```powershell
pwsh -File tools/Run-NonLVChecksInDocker.ps1
```

The script pulls pinned images (actionlint, node, PowerShell, python) and forwards only approved env vars (compatible with `DETERMINISTIC=1`). Add switches such as `-SkipDocs`/`-SkipWorkflow`/`-SkipMarkdown` to focus on specific checks, then rerun the VS Code task to verify fixes.

## Bundled workflows

- **Validate** – end-to-end self-hosted validation (fixtures, LVCompare, Pester suites).
- **Smoke** – minimal regression guard for documentation-only changes.
- **Fixture Drift** – verifies fixture manifests and retains comparison evidence.
- **VI Binary Gate** – ensures LabVIEW binaries remain normalized.
- **Markdownlint** – runs `npm run lint:md:changed` with the trimmed configuration below.

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
| Integration runbook | `docs/INTEGRATION_RUNBOOK.md` |
| Troubleshooting | `docs/TROUBLESHOOTING.md` |
| Traceability (requirements ↔ tests) | `docs/TRACEABILITY_GUIDE.md` |

## Contributing

1. Branch from `develop`, run `npm ci`.
2. Execute tests (`./Invoke-PesterTests.ps1` or watcher-assisted workflows).
3. Lint (`npm run lint:md:changed`, `tools/Check-ClangFormat.ps1` if relevant).
4. Submit a PR referencing **#88** and include rationale plus artifacts.

Follow `AGENTS.md` for coding etiquette and keep CI deterministic. Large workflow updates
should note affected jobs and link to supporting ADRs.

## Support & feedback

- File issues: <https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues>
- Contact NI for LabVIEW licensing questions.
- For agent coordination, follow the steps in `AGENT_HANDOFF.txt`.
