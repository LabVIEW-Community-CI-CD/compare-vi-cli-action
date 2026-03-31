# Manual VI Compare (refs) Workflow

## Overview

- The `Manual VI Compare (refs)` workflow now walks the first-parent history for a target VI and runs
  `LVCompare` against each commit->parent pair.
- `tools/Compare-VIHistory.ps1` orchestrates the compare loop, records results under
  `tests/results/ref-compare/history/`, and now emits a suite manifest (`vi-compare/history-suite@v1`)
  alongside per-mode manifests inside `<results>/<mode-slug>/`.
- Artifacts only include detailed LVCompare output when a difference is detected; runs with no diffs upload the lightweight
  manifest and JSON summaries.
- Pre-tag release readiness now uses the hosted release-branch evidence lanes: the latest
  `validate.yml` and `fixture-drift.yml` runs must both be green and publish artifacts before
  `release:finalize` can proceed.
- The manual self-hosted `vi-compare-refs.yml` and `vi-staging-smoke.yml` workflows remain available for
  focused Windows/LVCompare investigation, but they are no longer the blocking release gate.

## Pull request staging helper

- Comment `/vi-stage` on a pull request (legacy path, retired) to have the automation generate a manifest with
  `tools/Get-PRVIDiffManifest.ps1`, stage the resolvable base/head pairs via `tools/Invoke-PRVIStaging.ps1`, and upload a
  zipped bundle per staged pair.
- The workflow runs on the repository's hosted Linux runner (`ubuntu-latest`) so the same LabVIEW/LVCompare
  environment used in production compares is exercised during staging, and immediately launches `Invoke-LVCompare.ps1`
  against each staged pair. The capture artifacts (HTML report, `lvcompare-capture.json`, stdout/stderr) are stored under
  `vi-compare-artifacts/compare/pair-XX/` and summarised in the PR comment.
- The staging smoke helper ships a baked catalog so every run produces deterministic LVCompare output. The current scenarios are:

  | Scenario        | Fixture prep                                                                 | Expected LVCompare |
  |-----------------|------------------------------------------------------------------------------|--------------------|
  | `no-diff`       | Copy `fixtures/vi-attr/Head.vi` onto `Base.vi`                               | match              |
  | `vi2-diff`      | Write tracked fixtures `tmp-commit-236ffab/{VI1,VI2}.vi` into `fixtures/vi-attr/{Base,Head}.vi` (block diagram cosmetic diff) | diff |
  | `attr-diff`     | Stage the attribute fixtures `fixtures/vi-attr/attr/{BaseAttr,HeadAttr}.vi`  | diff               |
  | `fp-cosmetic`   | Stage `fixtures/vi-stage/fp-cosmetic/{Base,Head}.vi` (front panel cosmetic tweak) | diff |
  | `connector-pane`| Stage `fixtures/vi-stage/connector-pane/{Base,Head}.vi` (connector assignment change) | diff |
  | `bd-cosmetic`   | Stage `fixtures/vi-stage/bd-cosmetic/{Base,Head}.vi` (block-diagram cosmetic label) | diff |
  | `control-rename`| Stage `fixtures/vi-stage/control-rename/{Base,Head}.vi` (control rename) | diff |
  | `fp-window`     | Stage `fixtures/vi-stage/fp-window/{Base,Head}.vi` (window sizing change) | diff |

  The attribute fixtures live alongside the baseline set so we can keep the scenario data in-source without editing binaries in place. Update them only when you intend to change the smoke baseline.
  The PR comment table now appends per-category detail lines (for example `VI Attribute - Documentation � Description`) so attribute-only changes are visible at a glance. Additional atomic fixtures live under `fixtures/vi-stage/`; update those copies in LabVIEW (or via LabVIEW CLI) before wiring more scenarios into `tools/Test-PRVIStagingSmoke.ps1`.
- The workflow path above is retained for historical context only; use the local helper scripts for new runs.
- Outputs:
  - `vi-compare-manifest` artifact containing `vi-manifest.json`, `vi-staging-results.json` (full JSON payload), and a
    Markdown summary table.
  - `vi-compare-staging` artifact (when any pairs staged) with numbered `vi-staging-XX.zip` archives. Each zip mirrors the
    staging directory returned by `Stage-CompareInputs.ps1`, so reviewers can launch LVCompare locally without hand-
    gathering source files.
- LVCompare flags can be overridden with repository variables: `VI_STAGE_COMPARE_FLAGS_MODE` (defaults to `replace`),
  `VI_STAGE_COMPARE_FLAGS` (newline-separated list), and `VI_STAGE_COMPARE_REPLACE_FLAGS` (boolean override).
  The default `replace` mode removes the legacy "quiet" ignore bundle so attribute differences surface automatically,
  and the workflow always runs an additional `full` pass with no ignore flags so block diagram/front panel edits remain
  visible even when filters are configured. Reports now ship in the multi-file HTML layout (`compare-report.html`
  alongside `compare-report_files/`) so LVCompare 2025 exposes per-category headings and image assets. Set
  `COMPAREVI_REPORT_FORMAT=html-single` when you explicitly need the legacy single-file output.
- The workflow posts a PR comment with a bullet summary (pairs staged/skipped, AllowSameLeaf count, mode breakdown,
  LVCompare totals), followed by a collapsible table that mirrors the Markdown summary file. The table is generated by
  `tools/Summarize-VIStaging.ps1`, so each row now includes diff-category badges (signal entries render in green,
  cosmetic/noise entries pick up the amber `cat-noise` styling) and links to the exported reports relative to the
  `compare/` artifact. A new **Flags** column enumerates every LVCompare mode that ran (for example the filtered
  configuration plus the unsuppressed `full` pass) so reviewers can see which ignore bundles were active. The JSON
  summary captures the structured details via `diffCategoryDetails`, the per-mode metadata under `modes`, and aggregates
  them into `totals.categoryCounts`, so downstream automation can filter noise or build dashboards without re-parsing
  the HTML. Even when no pairs stage you receive a confirmation plus the run link.
- Successful runs now add the `vi-staging-ready` label to the PR (configurable via workflow input) so reviewers can spot staged bundles at a glance. The label is removed automatically if staging finds no VI pairs or the workflow fails.
- A dedicated smoke workflow (`Smoke VI Staging`) is available via manual dispatch; it exercises the helper end-to-end and uploads the summary artifact for traceability.
- The summary and PR comment include direct download links for the `vi-compare-manifest` and `vi-compare-staging` artifacts (links expire after roughly one hour; rerun `/vi-stage` to refresh).
- Both the Markdown summary and PR comment now list the business buckets alongside raw categories
  (`Buckets: Functional behavior, Metadata`, etc.) and the JSON payloads expose structured bucket counts. Reviewers or
  automation can triage differences by bucket rather than re-parsing LVCompare output, and fork smokes gate on the bucket
  coverage signal.
- Local parity: the same experience can be reproduced offline with
  ```powershell
  pwsh -File tools/Get-PRVIDiffManifest.ps1 -BaseRef origin/develop -HeadRef HEAD -OutputPath vi-manifest.json
  $results = pwsh -File tools/Invoke-PRVIStaging.ps1 -ManifestPath vi-manifest.json -WorkingRoot .\vi-staging
  ```
  Compress the `Root` directories from `$results` when you want to share the bundles manually.
- Once the compare run completes locally, feed `vi-staging-compare.json` to `tools/Summarize-VIStaging.ps1` to review
  the same Markdown/JSON summary that the workflow posts to the PR:
  ```powershell
  pwsh -File tools/Summarize-VIStaging.ps1 `
    -CompareJson .\vi-compare-artifacts\compare\vi-staging-compare.json `
    -MarkdownPath ./vi-staging-compare.md `
    -SummaryJsonPath ./vi-staging-compare-summary.json
  ```
- `VI Compare (Fork PR)` runs automatically when a pull request targeting `develop` originates from a fork. The workflow
  checks out the base/head commits, generates a `vi-diff-manifest.json` with `tools/Get-PRVIDiffManifest.ps1`, stages
  pairs via `tools/Invoke-PRVIStaging.ps1`, runs `tools/Run-StagedLVCompare.ps1`, renders the Markdown/JSON summary with
  `tools/Summarize-VIStaging.ps1`, and uploads the compare artifacts. It executes on the trusted self-hosted Windows
  runner (`self-hosted, Windows, X64`) and keeps the job read-only (no pushes/releases), so reviewers get deterministic
  LVCompare bundles at the start of every fork PR without manual staging.
- Rehearse the fork path with `tools/Test-ForkSimulation.ps1`: start with `-DryRun` to review the plan, run the helper
  normally to open a draft PR and validate the automatic compare job, then repeat with `-KeepBranch` when you want the
  scratch branch preserved while the `/vi-stage` and `/vi-history` dispatches finish.
- Comment `/vi-history` when you want the automation to walk commit history for every VI in the PR. The companion
  workflow path is retired; use `tools/Invoke-PRVIHistory.ps1` directly (which now walks every
  reachable commit pair by default; add `max_pairs=<n>` in the comment or `-MaxPairs <n>` locally when you need a
  deliberate cap; enable `-Verbose` locally to see the resolved helper and whether we lifted the path from the base or
  head tree), renders the Markdown table via `tools/Summarize-PRVIHistory.ps1`, uploads `tests/results/pr-vi-history/`,
  and replies to the PR with the same table.
  The `tools/Test-PRVIHistorySmoke.ps1` helper now also verifies that the PR comment lands successfully when the workflow
  finishes, so a green smoke run means reviewers can rely on the summary table without spelunking artifacts. Pass
  `-Scenario sequential` to replay a multi-category fixture chain and validate the richer history dashboard before
  exercising a live pull request.
  ```powershell
  pwsh -File tools/Get-PRVIDiffManifest.ps1 -BaseRef origin/develop -HeadRef HEAD -OutputPath vi-history-manifest.json
  pwsh -File tools/Invoke-PRVIHistory.ps1 -ManifestPath vi-history-manifest.json -ResultsRoot tests/results/pr-vi-history
  pwsh -File tools/Summarize-PRVIHistory.ps1 -SummaryPath tests/results/pr-vi-history/vi-history-summary.json -MarkdownPath vi-history-summary.md
  ```
  Mobile preview extraction writes additive artifacts per target:
  - `tests/results/pr-vi-history/<target>/previews/history-image-*`
  - `tests/results/pr-vi-history/<target>/vi-history-image-index.json`
    (`schema: pr-vi-history-image-index@v1`)
  The rendered summary/comment includes `### Mobile Preview` with inline `<img ...history-image-...>` tags, capped by
  comment safety limits. Totals expose `previewImages` and `markdownTruncated`; per-target metadata surfaces under
  `targets[].reportImages` in `pr-vi-history-summary@v1`.
  For a full end-to-end validation, run the smoke helper (`pwsh -File tools/Test-PRVIHistorySmoke.ps1` or `node tools/npm/run-script.mjs smoke:vi-history`) to create a scratch PR, dispatch the workflow, and record the results under `tests/results/_agent/smoke/vi-history/`.
  Benchmark/delta evidence is emitted alongside smoke summaries under
  `tests/results/_agent/smoke/vi-history/benchmarks/` (`vi-history-benchmark@v1` and
  `vi-history-benchmark-delta@v1`) with a markdown comment body ready for PR/issue posting.

## Dispatch inputs (GitHub UI or `gh workflow run`)

- `vi_path` (required): repository-relative `.vi` path (example `Fixtures/Loop.vi`). Use the exact casing committed
  to git.
- `compare_ref` (optional): branch/tag/commit where the walk begins. Defaults to `HEAD` when blank.
- `compare_depth` (optional): limit comparisons (set to `"0"` for no limit). The workflow now defaults to `0`.
  - Input must be a non-negative integer; anything else fails fast with a clear message.
- `compare_fail_fast` (`true`/`false`): stop iterating after the first detected diff (still uploads results, does not fail the job).
- `compare_fail_on_diff` (`true`/`false`): exit the job with failure status if any LVCompare run reports differences.
- `compare_modes` (string): comma-separated compare modes. Recognised values:
  - `default` - legacy suppressed bundle (`-nobd -noattr -nofp -nofppos -nobdcosm`).
  - `attributes` - keep attribute diffs visible while suppressing front panel
    and block diagram surfaces.
  - `front-panel` - keep front panel diffs visible while suppressing
    attributes and block diagram surfaces.
  - `block-diagram` - keep block diagram diffs visible while suppressing
    attributes and front panel surfaces.
- `full` - run LVCompare with no ignore flags (`-nobd`, `-noattr`, `-nofp`, `-nofppos`,
  `-nobdcosm` all disabled). Use when you need every cosmetic and functional change.
- `all` - alias for `full` (deprecated; the helper rewrites to `full` and emits a warning).
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
- **Deep dive** - leave `compare_depth` at `0` (or set it explicitly) and enable `compare_fail_fast='true'` when you just need to know whether any
  difference exists in the history span.

### Local automation helpers

- `scripts/Run-VIHistory.ps1` regenerates local history results, prints the enriched Markdown summary (including attribute coverage), previews the first few commit pairs it processed, and drops both `history-context.json` (commit metadata, when available) and `history-report.md` (single-document summary; plus `history-report.html` when `-HtmlReport`) under the history results directory. When the context JSON is missing or corrupted, the renderer derives the commit table directly from the per-mode manifests and queries `git` for author/date/subject details so the report still carries complete coverage information. If the renderer itself is unavailable, the helper writes a lightweight fallback report so the Markdown summary is always present:
    ```powershell
    pwsh -File scripts/Run-VIHistory.ps1 -ViPath Fixtures/Loop.vi -StartRef HEAD
    ```
- `scripts/Dispatch-VIHistoryWorkflow.ps1` dispatches the GitHub workflow with consistent parameters once you are happy with the local preview:
  ```powershell
  pwsh -File scripts/Dispatch-VIHistoryWorkflow.ps1 -ViPath Fixtures/Loop.vi -CompareRef develop -NotifyIssue 316
  ```
- When you just need the HTML comparison report for a pair of VIs, you can bypass the helper and call the LabVIEW CLI
  directly (from Fork's external diff tools or a standalone terminal). The command below mirrors the setup used in the
  community discussion on HTMLSingleFile output:
  ```powershell
  "C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe" `
    -OperationName CreateComparisonReport `
    -vi1 "C:\repo\icon-editor\resource\plugins\NIIconEditor\Legacy\Settings Init.vi" `
    -vi2 "C:\repo\icon-editor\resource\plugins\NIIconEditor\Miscellaneous\Settings Init.vi" `
    -reportType HTMLSingleFile `
    -o -nobdcosm `
    -reportPath "C:\temp\VI_Comparison.html"
  ```
  - Ensure the LabVIEW instance backing the CLI has VI Server enabled on port **3363** (Tools → Options → VI Server).
    The CLI fails silently when the port does not match.
  - CLI logs live under `%LOCALAPPDATA%\Temp` (the command output prints the exact path).
  - Adjust the ignore flags to match the mode you are reproducing (`-nobdcosm` in the example mirrors the historical
    `default` suppression bundle; omit the flag for the new `full` mode).

Example CLI dispatch (requires `gh workflow run` permissions):

```powershell
gh workflow run vi-compare-refs.yml `
  -f vi_path='VI1.vi' `
  -f compare_ref='develop' `
  -f compare_depth='0' `
  -f compare_fail_fast='true'
```

## Outputs & artifacts

- The compare step writes `tests/results/ref-compare/history/manifest.json`, an aggregate manifest with
  `schema: vi-compare/history-suite@v1`. The public contract is described in
  `docs/schemas/vi-compare-history-suite-v1.schema.json`: top-level `requestedModes[]` records the normalized requested
  mode bundle, `executedModes[]` records the modes that actually ran, and each `modes[]` entry captures the mode slug,
  resolved flag bundle, stable per-mode stats, and the `manifestPath` for that mode's detailed results.
- `scripts/Run-VIHistory.ps1` also writes `tests/results/ref-compare/history/history-context.json` (`schema: vi-compare/history-context@v1`) summarising the commit pairs whenever the upstream context file is present. If the context cannot be read, the renderer falls back to the per-mode manifests and enriches them with commit metadata pulled from `git`, ensuring the generated `history-report.md` / `history-report.html` still lists every pair with author/date context, explicit diff outcome, run duration, and-when differences exist-relative links to the LVCompare report and preserved artifact directory.
- The Markdown/HTML history reports include a `Categories` column that surfaces the same badge set as staging (`cat-signal`, `cat-noise`, `cat-neutral`). Each comparison record in the per-mode manifests carries the raw category slug list so tooling can distinguish signal vs cosmetic diffs without re-scraping the HTML.
- Reports now surface the normalized requested/executed mode bundle directly in both Markdown and HTML, and the
  per-mode overview tables include `Diffs`, `Signal`, `Collapsed Noise`, `Missing`, `Categories`, `Buckets`, and
  `Flags`. Reviewers should treat `Signal` as the high-value mode-specific diff count and `Collapsed Noise` as the
  count of diffs hidden by the configured noise policy.
- Reports also add a `Buckets` column and aggregate bucket totals so reviewers can immediately see whether a run touched
  functional behaviour, UI/visual changes, or metadata-only adjustments. The GitHub outputs ship both `category-counts-json`
  and `bucket-counts-json`, keeping dashboards in sync with the human-readable summaries.
- GitHub outputs include `manifest_path` (suite manifest), `results_dir` (root history directory), `mode_manifests_json`
  (JSON array enumerating each mode's manifest path, results directory, and stable summary stats including
  `processed`, `diffs`, `signalDiffs`, `noiseCollapsed`, `errors`, `missing`, `categoryCounts`, `bucketCounts`,
  `stopReason`, and `status`), plus `requested-mode-list`, `executed-mode-list`, the history report pointers, and
  `history-summary-json`. The compare step emits `history-report-md` / `history-report-html` plus
  `history-summary-json`, and the workflow surfaces the report paths for downstream jobs, dashboards, or PR comments.
  `history-summary.json` is the stabilized downstream facade (`comparevi-tools/history-facade@v1`) used by
  `Invoke-CompareVIHistoryFacade`. When HTML rendering is skipped or fails, the Markdown path still points at the
  fallback report so consumers always have a summary to ingest. A compressed `category-counts-json` blob is also
  published so downstream automation can react to runs dominated by cosmetic noise without re-reading the manifests.
  The facade's `decisionGuidance` block now carries a human-readable `decisionStatement`, the newest surfaced pair,
  and the review sequence with refs, subjects, and commit dates so downstream consumers can answer what changed, when,
  and whether it matters from one stabilized payload.
- History summary JSON (`tests/results/pr-vi-history/vi-history-summary.json`) now adds:
  - `targets[].reportImages` for per-target extraction metadata.
  - `pairTimeline[]` with additive per-pair contract fields:
    `targetPath`, `baseRef`, `headRef`, `classification`, `diff`, `durationSeconds`,
    `previewStatus`, `reportPath`, `imageIndexPath`.
  - top-level `kpi` envelope:
    `signalRecall`, `noisePrecisionMasscompile`, `previewCoverage`,
    `timingP50Seconds`, `timingP95Seconds`, `commentTruncated`, `truncationReason`.
  - classification enum for `pairTimeline[].classification`:
    `signal | noise-masscompile | noise-cosmetic | unknown`.
  - totals `previewImages` / `markdownTruncated` so downstream checks can verify image extraction and comment-size
    truncation deterministically.
- Minimal example (additive fields only):
  ```json
  {
    "schema": "pr-vi-history-summary@v1",
    "pairTimeline": [
      {
        "targetPath": "fixtures/vi-attr/Head.vi",
        "baseRef": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "headRef": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "classification": "signal",
        "diff": true,
        "durationSeconds": 1.25,
        "previewStatus": "present",
        "reportPath": "tests/results/pr-vi-history/01.../history-report.html",
        "imageIndexPath": "tests/results/pr-vi-history/01.../vi-history-image-index.json"
      }
    ],
    "kpi": {
      "signalRecall": 1.0,
      "noisePrecisionMasscompile": null,
      "previewCoverage": 1.0,
      "timingP50Seconds": 1.25,
      "timingP95Seconds": 1.25,
      "commentTruncated": false,
      "truncationReason": "none"
    }
  }
  ```
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
- The step-summary also prints bucket totals per run (`Bucket counts: Functional behavior (3), Metadata (1)`), mirroring
  the JSON output so pasted acceptance notes retain the same context reviewers see on the workflow run.
- When `notify_issue` is set, the workflow posts the same table to the referenced issue so stakeholders can track results.

## Running the helper locally

- Use the same helper to triage history without GitHub Actions:

  ```powershell
  pwsh -NoLogo -NoProfile -File tools/Compare-VIHistory.ps1 `
    -TargetPath VI1.vi `
    -StartRef HEAD `
    -Detailed `
    -RenderReport
  ```
  Add `-MaxPairs <n>` when you intentionally need to limit the number of comparisons.

- Combine `-FailFast` to stop after the first difference or `-FailOnDiff` to exit non-zero for gating scripts.
- The helper writes the suite manifest plus per-mode directories under `tests/results/ref-compare/history/` by default;
  override via `-ResultsDir`.
- Set `-AdditionalFlags` when you need extra LVCompare switches (for example `-AdditionalFlags '-noconpane -noselect'`).
- Pass `-Mode attributes` / `-Mode 'front-panel'` / `-Mode 'block-diagram'` / `-Mode full` to mirror the workflow modes locally.
- Use `-Mode full` for a single pass with *no* suppression flags (all of the `-nobd`, `-noattr`, `-nofp`, `-nofppos`, `-nobdcosm` ignores removed). The production workflow now runs `full` alongside `default`, so local runs should include both when you want parity (`-Mode 'default,full'`).

### Source control settings

- Before launching LabVIEWCLI, the helper inspects the active `LabVIEW.ini` for source-control keys (`SCCUseInLabVIEW`,
  `SCCProviderIsActive`). When either value is `True`, the script logs a warning because headless compare sessions will
  trigger LabVIEW's SCC connector and surface the 0x401 “Application Reference is invalid” dialog. Disable source control
  inside LabVIEW (Tools → Options → Source Control) or set those INI keys to `False` to keep unattended runs quiet.

### Attribute-focused runs

- Include `attributes` in the `modes` list (or run the helper with `-Mode attributes`) to remove `-noattr` while leaving
  the other ignores intact. The manifest records `mode = "attributes"` and the step summary echoes the active mode so
  reviewers can spot attribute-only evaluations.
- Include `full` in the mode list (or run the helper with `-Mode full`) when you need a comparison with every ignore flag disabled. Expect longer runtimes and more cosmetic noise—the automation now opts into this by default (`compare_modes='default,full'`).
- Example CLI dispatch:

```powershell
gh workflow run vi-compare-refs.yml `
  -f vi_path='VI1.vi' `
  -f compare_ref='develop' `
  -f compare_modes='default,full'
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


### Fork pull request automation

- VI Compare (Fork PR) runs automatically on PRs targeting develop (including forks). The workflow fetches the fork head via the composite etch-pr-head helper, stages pairs, runs NI Linux container compare on hosted Linux, and uploads the same artifacts as /vi-stage.
- The command-driven `pr-vi-staging.yml` and `pr-vi-history.yml` workflows are retired.
- Manual `/vi-stage` and `/vi-history` dispatches accept an optional `fetch_depth` input (default `20`) so you can deepen history when needed.
- PRs no longer use auto-approval labels; queue admission depends on required checks and branch policy while deployment
  acknowledgement for protected promotion flows uses environment reviewers (`production` / `monthly-stability-release`).

### Acceptance checklist (bucket coverage)

- [ ] Fork smokes cover at least two staged VI pairs in a single run (for example `vi-attr/Base.vi` +
      `vi-stage/bd-functional.vi`) so functional and metadata buckets appear together.
- [ ] Staging summaries include bucket lines in both Markdown and PR comments, and the JSON payload exposes
      `totals.bucketCounts`.
- [ ] History reports (`history-report.md` / `.html`) render a `Buckets` column and the suite manifest exports
      `bucketCounts` alongside `categoryCounts`.
- [ ] GitHub outputs (`bucket-counts-json`) and telemetry carry the bucket totals so downstream automation can detect
      missing coverage.
- [ ] Documentation and helper usage notes stay in sync with the bucket terminology (Functional behavior, UI / visual,
      Metadata) and explain how to add new fixtures or buckets.
