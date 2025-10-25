# Compare VI CLI Action

## Overview

This repository hosts the reusable workflows and helper scripts that drive manual
LVCompare runs against commits in a LabVIEW project. The primary entrypoint is the
`Manual VI Compare (refs)` workflow, which walks a branch/ref history, extracts the
target VI at each commit→parent pair, and invokes LVCompare in headless mode.

The latest rev streamlines the workflow inputs so SMEs only need to provide:

1. The branch/tag/commit to inspect (`compare_ref`, defaults to `HEAD`)
2. The repository-relative VI path (`vi_path`)

Additional knobs remain available but defaulted so most runs require no extra
tuning.

## Quick start

### GitHub UI

1. Navigate to **Actions → Manual VI Compare (refs)**.
2. Click **Run workflow**.
3. Supply `vi_path` (for example `Fixtures/Loop.vi`) and, optionally,
   `compare_ref` if you want something other than the workflow branch tip.
4. Run the workflow. Results appear under the job summary with links to
   the generated manifests and any LVCompare diff artifacts.

### CLI (gh)

```powershell
gh workflow run vi-compare-refs.yml `
  -f vi_path='Fixtures/Loop.vi' `
  -f compare_ref='develop'
```

Use `gh run watch <run-id>` or the rendered summary to follow progress. The
workflow uploads two artifacts:

- `vi-compare-manifests` – aggregate suite manifest and per-mode summaries
- `vi-compare-diff-artifacts` – only present when LVCompare detects differences

## Optional inputs

| Input name               | Default   | Description                                                                 |
| ------------------------ | --------- | --------------------------------------------------------------------------- |
| `compare_depth`          | `10`      | Maximum commit pairs to evaluate (`0` = no limit)                           |
| `compare_modes`          | `default` | Comma/semicolon list of compare modes (`default,attributes,front-panel` …) |
| `compare_ignore_flags`   | `default` | LVCompare ignore toggles (`default`, `none`, or comma-separated flags)      |
| `compare_additional_flags` | ` `   | Extra LVCompare switches (space-delimited)                                  |
| `compare_fail_fast`      | `false`   | Stop after the first diff                                                   |
| `compare_fail_on_diff`   | `false`   | Fail the workflow when any diff is detected                                 |
| `sample_id`              | _(empty)_ | Optional concurrency key (advanced use)                                     |

These inputs map directly onto the parameters in `tools/Compare-VIHistory.ps1`,
so advanced behaviour remains available without cluttering the default UX.

## Local helper

You can run the same compare logic locally:

```powershell
pwsh -NoLogo -NoProfile -File tools/Compare-VIHistory.ps1 `
  -TargetPath Fixtures/Loop.vi `
  -StartRef develop `
  -MaxPairs 5 `
  -Detailed `
  -RenderReport
```

Artifacts are written under `tests/results/ref-compare/history/` using the same
schema as the workflow outputs.

## Release and compatibility

Renaming the workflow inputs breaks compatibility with previous revisions, so the
next release should cut a new major tag (for example `v1.0.0`). Update downstream
automation or scheduled triggers to use the new `vi_path` / `compare_ref` inputs
before adopting the release.
