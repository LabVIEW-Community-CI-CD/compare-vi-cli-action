# Manual VI Compare (refs) Workflow

## Overview

- The `Manual VI Compare (refs)` workflow now walks the first-parent history for a target VI and runs
  `LVCompare` against each commit->parent pair.
- `tools/Compare-VIHistory.ps1` orchestrates the compare loop, records results under
  `tests/results/ref-compare/history/`, and now emits a suite manifest (`vi-compare/history-suite@v1`)
  alongside per-mode manifests inside `<results>/<mode-slug>/`.
- Artifacts only include detailed LVCompare output when a difference is detected; runs with no diffs upload the lightweight
  manifest and JSON summaries.

## Dispatch inputs (GitHub UI or `gh workflow run`)

- `target_path` (required): repository-relative `.vi` path (example `Fixtures/Loop.vim`). Use the exact casing committed
  to git.
- `start_ref` (optional): commit/ref where the walk begins. Defaults to `HEAD` when blank.
- `end_ref` (optional): stop when this ref is reached. The pair that lands on `end_ref` is compared once, then the loop
  exits.
- `max_pairs` (optional): limit comparisons (set to `"0"` for no limit). The workflow defaults to `10`.
- `fail_fast` (`true`/`false`): stop iterating after the first detected diff (still uploads results, does not fail the job).
- `fail_on_diff` (`true`/`false`): exit the job with failure status if any LVCompare run reports differences.
- `modes` (string): comma-separated compare modes. Recognised values:
  - `default` – honour the ignore toggles (`flag_*` inputs).
  - `attributes` – drop `-noattr` so VI attribute changes surface.
  - `front-panel` – drop `-nofp`/`-nofppos` to observe FP layout changes.
  - `block-diagram` – drop `-nobdcosm` to surface BD cosmetic tweaks.
  - `all` – remove every ignore flag (`-nobd`, `-noattr`, `-nofp`, `-nofppos`, `-nobdcosm`).
  - `custom` – honour the flag toggles exactly as provided.
- Multiple modes can be supplied (e.g. `default,attributes`); the workflow loops over each and emits a manifest/artifact
  set per mode.
- Flag toggles map directly to LVCompare switches:
  - `flag_noattr` -> `-noattr`
  - `flag_nofp` -> `-nofp`
  - `flag_nofppos` -> `-nofppos`
  - `flag_nobdcosm` -> `-nobdcosm`
  - The helper always prepends `-nobd`. Add extra switches via `additional_flags` (space-delimited).

Example CLI dispatch (requires `gh workflow run` permissions):

```powershell
gh workflow run vi-compare-refs.yml `
  -f target_path='VI1.vi' `
  -f start_ref='develop' `
  -f max_pairs='5' `
  -f fail_fast='true'
```

## Outputs & artifacts

- The compare step writes `tests/results/ref-compare/history/manifest.json`, an aggregate manifest with
  `schema: vi-compare/history-suite@v1`. Each `modes[]` entry captures the mode slug, resolved flag bundle,
  stats, and the `manifestPath` for that mode’s detailed results.
- Per-mode manifests live under `tests/results/ref-compare/history/<mode>/manifest.json`
  (`schema: vi-compare/history@v1`) and enumerate the commit pairs, summaries, and LVCompare outcomes.
- Per-iteration summaries (`*-summary.json`) and execution traces (`*-exec.json`) are stored beside the mode manifest
  (for example `tests/results/ref-compare/history/default/VI1.vi-001-summary.json`) and uploaded in the
  `vi-compare-results` artifact.
- When LVCompare reports differences, the helper preserves the `*-artifacts` directory (HTML report, screenshots, stdout)
  within the mode directory, and the workflow uploads them as `vi-compare-diff-artifacts`. Runs without differences discard those directories so the
  diff artifact upload is skipped.
- The job summary includes a lightweight table with the total pairs processed, diff count, stop reason, and the most
  recent diff (if any).

## Running the helper locally

- Use the same helper to triage history without GitHub Actions:

  ```powershell
  pwsh -NoLogo -NoProfile -File tools/Compare-VIHistory.ps1 `
    -TargetPath VI1.vi `
    -StartRef HEAD `
    -MaxPairs 3 `
    -Detailed `
    -RenderReport
  ```

- Combine `-FailFast` to stop after the first difference or `-FailOnDiff` to exit non-zero for gating scripts.
- The helper writes the suite manifest plus per-mode directories under `tests/results/ref-compare/history/` by default;
  override via `-ResultsDir`.
- Set `-AdditionalFlags` when you need extra LVCompare switches (for example `-AdditionalFlags '-noconpane -noselect'`).
- Pass `-Mode attributes` / `-Mode 'front-panel'` / `-Mode 'block-diagram'` / `-Mode all` to mirror the workflow modes locally.

### Attribute-focused runs

- Include `attributes` in the `modes` list (or run the helper with `-Mode attributes`) to remove `-noattr` while leaving
  the other ignores intact. The manifest records `mode = "attributes"` and the step summary echoes the active mode so
  reviewers can spot attribute-only evaluations.
- Example CLI dispatch:

```powershell
gh workflow run vi-compare-refs.yml `
  -f target_path='VI1.vi' `
  -f start_ref='develop' `
  -f modes='default,attributes'
```

## Behaviour highlights

- The helper validates that the target VI exists at the start/end refs and at each parent before invoking LVCompare.
  Missing files raise an actionable message with the failing SHA.
- When the requested start ref does not change the target VI, the helper automatically walks to the nearest commit that
  does (preferring newer commits first, then older ones as a fallback).
- Commit traversal uses `git rev-list --first-parent` to honour linear history; provide a branch or commit SHA in
  `start_ref` for non-`HEAD` runs.
- When a parent commit does not contain the target VI (for example the commit where it was introduced), the manifest
  records the pair with `status = "missing-base"` and the loop keeps going. Once the walk reaches a commit where the VI
  itself is missing, the helper emits a final `missing-head` entry and stops.
- Artifacts for no-diff runs stay lightweight (<5 KB) so you can keep the workflow optional without overwhelming CI
  storage.
