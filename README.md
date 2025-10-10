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

Status JSON contains `state`, heartbeat freshness, and byte counters - ideal for hand-offs or
CI summaries.

### TestStand harness

- `npm run teststand:compare -- --base fixtures/VI1.vi --head fixtures/VI2.vi`
  - Invokes `tools/TestStand-CompareHarness.ps1` via the Node wrapper.
  - Artifacts (warmup log, compare log, capture JSON, optional report) land under
    `tests/results/teststand-session/` with a `session-index.json`
    (`teststand-compare-session/v1`).
  - Optional flags: `--labview`, `--lvcompare`, `--render-report`, `--close-labview`,
    `--close-lvcompare`, and `--repo-root` for alternate harness roots (smoke tests).

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
