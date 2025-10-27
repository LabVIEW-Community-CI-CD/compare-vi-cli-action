# Manual VI Compare (refs) Workflow

## Overview

- The `Manual VI Compare (refs)` workflow now walks the first-parent history for a target VI and runs
  `LVCompare` against each commit->parent pair.
- `tools/Compare-VIHistory.ps1` orchestrates the compare loop, records results under
  `tests/results/ref-compare/history/`, and now emits a suite manifest (`vi-compare/history-suite@v1`)
  alongside per-mode manifests inside `<results>/<mode-slug>/`.
- Artifacts only include detailed LVCompare output when a difference is detected; runs with no diffs upload the lightweight
  manifest and JSON summaries.

## Pull request staging helper

- Comment `/vi-stage` on a pull request (or dispatch `pr-vi-staging.yml`) to have the automation generate a manifest with
  `tools/Get-PRVIDiffManifest.ps1`, stage the resolvable base/head pairs via `tools/Invoke-PRVIStaging.ps1`, and upload a
  zipped bundle per staged pair.
- The workflow only honours comments authored by repository members/collaborators. Maintainers can also run the job
  manually with `gh workflow run pr-vi-staging.yml -f pr=<number> [-f note="context"]`.
- Outputs:
  - `vi-compare-manifest` artifact containing `vi-manifest.json`, `vi-staging-results.json` (full JSON payload), and a
    Markdown summary table.
  - `vi-compare-staging` artifact (when any pairs staged) with numbered `vi-staging-XX.zip` archives. Each zip mirrors the
    staging directory returned by `Stage-CompareInputs.ps1`, so reviewers can launch LVCompare locally without hand-
    gathering source files.
- The workflow posts a PR comment summarising the staged pairs and linking back to the run artifacts; the job summary
  mirrors the same table. For zero staged pairs you still get a quick confirmation and run link.
- Successful runs now add the `vi-staging-ready` label to the PR (configurable via workflow input) so reviewers can spot staged bundles at a glance. The label is removed automatically if staging finds no VI pairs or the workflow fails.
- A dedicated smoke workflow (`Smoke VI Staging`) is available via manual dispatch; it exercises the helper end-to-end and uploads the summary artifact for traceability.
- The summary and PR comment include direct download links for the `vi-compare-manifest` and `vi-compare-staging` artifacts (links expire after roughly one hour; rerun `/vi-stage` to refresh).
- Local parity: the same experience can be reproduced offline with
  ```powershell
  pwsh -File tools/Get-PRVIDiffManifest.ps1 -BaseRef origin/develop -HeadRef HEAD -OutputPath vi-manifest.json
  $results = pwsh -File tools/Invoke-PRVIStaging.ps1 -ManifestPath vi-manifest.json -WorkingRoot .\vi-staging
  ```
  Compress the `Root` directories from `$results` when you want to share the bundles manually.

## Dispatch inputs (GitHub UI or `gh workflow run`)

- `vi_path` (required): repository-relative `.vi` path (example `Fixtures/Loop.vi`). Use the exact casing committed
  to git.
- `compare_ref` (optional): branch/tag/commit where the walk begins. Defaults to `HEAD` when blank.
- `compare_depth` (optional): limit comparisons (set to `"0"` for no limit). The workflow defaults to `10`.
  - Input must be a non-negative integer; anything else fails fast with a clear message.
- `compare_fail_fast` (`true`/`false`): stop iterating after the first detected diff (still uploads results, does not fail the job).
- `compare_fail_on_diff` (`true`/`false`): exit the job with failure status if any LVCompare run reports differences.
- `compare_modes` (string): comma-separated compare modes. Recognised values:
  - `default` - compare with no ignore flags (full detail).
  - `attributes` - apply `-noattr` to suppress attribute-only differences when you want a quieter run.
  - `front-panel` - apply `-nofp`/`-nofppos` to suppress front panel layout changes.
  - `block-diagram` - apply `-nobdcosm` to suppress block diagram cosmetic tweaks.
  - `all` - synonym for `default` (retained for backwards compatibility).
  - `custom` - honour the ignore list supplied via `compare_ignore_flags` exactly as provided.
- Multiple modes can be supplied (e.g. `default,attributes`); the workflow loops over each and emits a manifest/artifact
  set per mode.
- `compare_ignore_flags` (string): comma-separated LVCompare ignore toggles. Accepts `default` (reapply the legacy suppression bundle `noattr,nofp,nofppos,nobdcosm`),
  `none` (apply none; this is the default), direct flag names (`noattr`, `nofp`, `nofppos`, `nobdcosm`), and `+flag` / `-flag` modifiers
  to add or remove flags relative to the current set.
- Need additional switches (e.g. `-nobd`)? Add them via `compare_additional_flags` (space-delimited).
- `notify_issue` (string, optional): GitHub issue number that should receive the run summary table as a comment. Ignored on forks.

### Quick-start scenarios

- **Default history sweep** - leave inputs at their defaults and supply only `vi_path`. The workflow walks the first
  ten commit pairs starting at `HEAD`, surfaces every difference (no suppression), and uploads a lightweight manifest.
- **Attribute audit** - set `compare_modes` to `default,attributes` so the second pass runs with `-noattr`, letting you contrast the full-detail manifest against a suppressed one.
- **Deep dive** - bump `compare_depth` to `0` (unbounded) and enable `compare_fail_fast='true'` when you just need to know whether any
  difference exists in the history span.

### Local automation helpers

- `scripts/Run-VIHistory.ps1` regenerates local history results, prints the enriched Markdown summary (including attribute coverage), previews the first few commit pairs it processed, and drops both `history-context.json` (commit metadata, when available) and `history-report.md` (single-document summary; plus `history-report.html` when `-HtmlReport`) under the history results directory. When the context JSON is missing or corrupted, the renderer derives the commit table directly from the per-mode manifests and queries `git` for author/date/subject details so the report still carries complete coverage information. If the renderer itself is unavailable, the helper writes a lightweight fallback report so the Markdown summary is always present:
    ```powershell
    pwsh -File scripts/Run-VIHistory.ps1 -ViPath Fixtures/Loop.vi -StartRef HEAD -MaxPairs 3
    ```
- `scripts/Dispatch-VIHistoryWorkflow.ps1` dispatches the GitHub workflow with consistent parameters once you are happy with the local preview:
  ```powershell
  pwsh -File scripts/Dispatch-VIHistoryWorkflow.ps1 -ViPath Fixtures/Loop.vi -CompareRef develop -NotifyIssue 316
  ```

Example CLI dispatch (requires `gh workflow run` permissions):

```powershell
gh workflow run vi-compare-refs.yml `
  -f vi_path='VI1.vi' `
  -f compare_ref='develop' `
  -f compare_depth='5' `
  -f compare_fail_fast='true'
```

## Outputs & artifacts

- The compare step writes `tests/results/ref-compare/history/manifest.json`, an aggregate manifest with
  `schema: vi-compare/history-suite@v1`. Each `modes[]` entry captures the mode slug, resolved flag bundle,
  stats, and the `manifestPath` for that mode's detailed results.
- `scripts/Run-VIHistory.ps1` also writes `tests/results/ref-compare/history/history-context.json` (`schema: vi-compare/history-context@v1`) summarising the commit pairs whenever the upstream context file is present. If the context cannot be read, the renderer falls back to the per-mode manifests and enriches them with commit metadata pulled from `git`, ensuring the generated `history-report.md` / `history-report.html` still lists every pair with author/date context, explicit diff outcome, run duration, and—when differences exist—relative links to the LVCompare report and preserved artifact directory.
- GitHub outputs include `manifest_path` (suite manifest), `results_dir` (root history directory), `mode_manifests_json`
  (JSON array enumerating each mode's manifest path, results directory, and summary stats), plus the history report
  pointers. The compare step emits `history-report-md` / `history-report-html`, and the workflow surfaces those as job
  outputs `history_report_md` / `history_report_html` for downstream jobs, dashboards, or PR comments. When HTML
  rendering is skipped or fails, the Markdown path still points at the fallback report so consumers always have a
  summary to ingest.
- Per-mode manifests live under `tests/results/ref-compare/history/<mode>/manifest.json`
  (`schema: vi-compare/history@v1`) and enumerate the commit pairs, summaries, and LVCompare outcomes.
- Per-iteration summaries (`*-summary.json`) live beside the mode manifest
  (for example `tests/results/ref-compare/history/default/VI1.vi-001-summary.json`) and are uploaded in the
  `vi-compare-manifests` artifact. Execution traces (`*-exec.json`) stay on disk for local triage but are no longer
  included in the workflow artifact to keep uploads lean.
- When LVCompare reports differences, the helper preserves the `*-artifacts` directory (HTML report, screenshots, stdout)
  within the mode directory, and the workflow uploads them as `vi-compare-diff-artifacts`. Runs without differences discard those directories so the
  diff artifact upload is skipped.
- The job summary includes a Markdown table for each mode (processed pairs, diff count, missing count, and last diff details).
- When `notify_issue` is set, the workflow posts the same table to the referenced issue so stakeholders can track results.

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

### Source control settings

- Before launching LabVIEWCLI, the helper inspects the active `LabVIEW.ini` for source-control keys (`SCCUseInLabVIEW`,
  `SCCProviderIsActive`). When either value is `True`, the script logs a warning because headless compare sessions will
  trigger LabVIEW's SCC connector and surface the 0x401 “Application Reference is invalid” dialog. Disable source control
  inside LabVIEW (Tools → Options → Source Control) or set those INI keys to `False` to keep unattended runs quiet.

### Attribute-focused runs

- Include `attributes` in the `modes` list (or run the helper with `-Mode attributes`) to remove `-noattr` while leaving
  the other ignores intact. The manifest records `mode = "attributes"` and the step summary echoes the active mode so
  reviewers can spot attribute-only evaluations.
- Example CLI dispatch:

```powershell
gh workflow run vi-compare-refs.yml `
  -f vi_path='VI1.vi' `
  -f compare_ref='develop' `
  -f compare_modes='default,attributes'
```

## Behaviour highlights

- The helper validates that the target VI exists at the start/end refs and at each parent before invoking LVCompare.
  Missing files raise an actionable message with the failing SHA.
- When the requested start ref does not change the target VI, the helper automatically walks to the nearest commit that
  does (preferring newer commits first, then older ones as a fallback).
- Commit traversal uses `git rev-list --first-parent` to honour linear history; provide a branch or commit SHA in
  `compare_ref` for non-`HEAD` runs.
- When a parent commit does not contain the target VI (for example the commit where it was introduced), the manifest
  records the pair with `status = "missing-base"` and the loop keeps going. Once the walk reaches a commit where the VI
  itself is missing, the helper emits a final `missing-head` entry and stops.
- Artifacts for no-diff runs stay lightweight (<5 KB) so you can keep the workflow optional without overwhelming CI
  storage.
