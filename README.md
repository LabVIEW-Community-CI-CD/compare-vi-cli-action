# Compare VI CLI Action

## Overview

This repository hosts the reusable workflows and helper scripts that drive manual
LVCompare runs against commits in a LabVIEW project. The primary entrypoint is the
`Manual VI Compare (refs)` workflow, which walks a branch/ref history, extracts the
target VI at each commit-parent pair, and invokes LVCompare in headless mode.

Scope boundary: icon editor development is out of scope for this repository. The
active icon editor project lives at `svelderrainruiz/labview-icon-editor`.
The canonical downstream local-first adoption proof surface for VI history is
`LabVIEW-Community-CI-CD/labview-icon-editor-demo` on `develop`.

The latest rev streamlines the workflow inputs so SMEs only need to provide:

1. The branch/tag/commit to inspect (`compare_ref`, defaults to `HEAD`)
2. The repository-relative VI path (`vi_path`)

Additional knobs remain available but defaulted so most runs require no extra
tuning.

## Trust and support status

- Supported stable release line: `v0.6.4`
- Future pre-release work may use `v0.6.x-rc` tags only when a later stable cut is being prepared
- License: `BSD-3-Clause`
- Full compare execution still assumes the maintained self-hosted Windows + LabVIEW + LVCompare runtime described in [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- This repository publishes the compare action surface and also carries maintainer/operator platform workflows; downstream consumers should start from the action contract and usage docs first
- Product boundary: [`docs/SUPPORTED_PRODUCT_BOUNDARY.md`](./docs/SUPPORTED_PRODUCT_BOUNDARY.md)
- Minimal adopter contract: [`docs/MINIMAL_ADOPTER_CONTRACT.md`](./docs/MINIMAL_ADOPTER_CONTRACT.md)
- Maintainer continuity profile: [`docs/MAINTAINER_CONTINUITY_PROFILE.md`](./docs/MAINTAINER_CONTINUITY_PROFILE.md)

## Documentation portal

Use the [GitHub wiki](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/wiki) as the public entry
portal for this repository. It is curated for fast navigation and links outward to the detailed checked-in docs.
The published wiki pages themselves live in GitHub's separate wiki backing repo,
`LabVIEW-Community-CI-CD/compare-vi-cli-action.wiki.git`.

The authoritative documentation still lives in this repository:

- `docs/` for runbooks, policy, and technical contracts
- `docs/SUPPORTED_PRODUCT_BOUNDARY.md` for the supported public-vs-platform scope boundary
- `docs/MINIMAL_ADOPTER_CONTRACT.md` for the shortest supported downstream adoption path
- `docs/FIRST_CONSUMER_SUCCESS_PATH.md` for the fastest supported path to downstream first success
- `docs/MAINTAINER_CONTINUITY_PROFILE.md` for the current ownership and recovery model
- `docs/WORKFLOW_CRITICALITY_MAP.md` for maintainer workflow tiers and release-critical lanes
- `AGENTS.md` for future-agent operating rules
- `docs/knowledgebase/GitHub-Intake-Layer.md` for issue/PR intake guidance
- `docs/knowledgebase/GitHub-Wiki-Portal.md` for the wiki-vs-repo-docs contract

## Quick start

### GitHub UI

1. Navigate to **Actions -> Manual VI Compare (refs)**.
2. Click **Run workflow**.
3. Supply `vi_path` (for example `Fixtures/Loop.vi`) and, optionally,
   `compare_ref` if you want something other than the workflow branch tip.
4. Run the workflow. The job summary includes a Markdown table of processed
   pairs, diff counts, and missing entries per mode; any differences raise a
   warning that points at the uploaded diff artifacts.

### CLI (gh)

```powershell
gh workflow run vi-compare-refs.yml `
  -f vi_path='Fixtures/Loop.vi' `
  -f compare_ref='develop'
```

Use `gh run watch <run-id>` or the rendered summary to follow progress. The
workflow uploads two artifacts:

- `vi-compare-manifests` - aggregate suite manifest and per-mode summaries
- `vi-compare-diff-artifacts` - only present when LVCompare detects differences

## Host-Native CLI

`comparevi-cli` now executes the real history/report backend for advanced
commands instead of returning contract-only placeholder payloads:

- `compare range` shells into `tools/Get-PRVIDiffManifest.ps1` and
  `tools/Invoke-PRVIHistory.ps1`
- `history run` shells into `tools/Invoke-PRVIHistory.ps1`
- `report consolidate` shells into `tools/Render-VIHistoryReport.ps1` and
  `tools/Extract-VIHistoryReportImages.ps1`

Successful runs write versioned JSON plus materialized Markdown/HTML/image-index
artifacts in the selected `--out-dir`. `--dry-run` remains available when you
only want the contract envelope without invoking the backend.

Validate and release lanes now also certify the extracted `CompareVI.Tools`
bundle across the public history mode bundle
(`default,attributes,front-panel,block-diagram`). That evidence is emitted as
`comparevi-history-bundle-certification@v1` JSON plus a rendered Markdown
summary under `tests/results/_agent/...`, so downstream consumers can inspect
the exact per-mode categories without relying on collapsed warning text alone.

When the CLI runs outside a full repository checkout, point it at a helper
bundle/repo root with `COMPAREVI_CLI_SCRIPTS_ROOT` (or `COMPAREVI_SCRIPTS_ROOT`).
For local validation and automated tests, `COMPAREVI_CLI_INVOKE_SCRIPT_PATH`
can override the compare invoker without changing the production workflow
contract.

## VS Code Plane Workspaces

Use the primary committed workspace files to keep upstream, fork, and
command-center operations explicit, while preserving the legacy alias:

- `compare-vi-cli-action.upstream-plane.code-workspace`
- `compare-vi-cli-action.fork-plane.code-workspace`
- `compare-vi-cli-action.command-center.code-workspace`
- `compare-vi-cli-action.code-workspace` (legacy alias for command-center)

Folder names inside those files follow plane prefixes (`PLANE_UPSTREAM__*`,
`PLANE_FORK__*`) and all included tasks pin `cwd` to a named workspace folder so
commands run in the intended plane.

See `docs/DUAL_PLANE_WORKSPACES.md` for the expected directory layout and task
usage, including the WSL distro guardrail (`Ubuntu`/standard distro, not
`docker-desktop`).

Runbook container canary promotion/rollback policy is tracked in
`docs/RUNBOOK_CONTAINER_LANE_PROMOTION_POLICY.md` (decision issue `#663`,
evidence source `#662`).

Release operating governance (roles, environment approvals, escalation, and incident/rollback protocol) is documented in
`docs/RELEASE_OPERATIONS_RUNBOOK.md`.

Each job also emits GitHub outputs pointing at the aggregate manifest, the
history results directory, the per-mode manifest summary (`mode-manifests-json`),
and the generated history report paths (`history-report-md` and, when HTML
renders, `history-report-html`). Downstream workflows and reusable snippets can
consume those keys to surface the Markdown/HTML report or to dispatch follow-up
automation without spelunking the artifacts. When the renderer is unavailable,
`Compare-VIHistory.ps1` writes a lightweight fallback report so the Markdown
output key always resolves to a readable summary.

Provide the optional `notify_issue` input when dispatching the workflow to post
the same summary table to a GitHub issue for stakeholders.

### PR staging helper at a glance

- Comment `/vi-stage` on a pull request (or run `gh workflow run pr-vi-staging.yml -f pr=<number>`).
- The workflow stages VI pairs via `tools/Invoke-PRVIStaging.ps1`, runs LVCompare on each, and posts a summary comment
  with staged/skipped counts, AllowSameLeaf totals, mode breakdown, and LVCompare results. A collapsible table mirrors
  the Markdown summary artifact and is generated by `tools/Summarize-VIStaging.ps1`, so it flags the compare categories
  (front panel, block diagram functional/cosmetic, VI attributes) that triggered for each pair and now includes a
  **Flags** column that lists the LVCompare mode(s) executed and the flag bundle applied.
- Artifacts: `vi-compare-manifest` (manifest + summary) and
  `vi-compare-staging` (numbered `vi-staging-XX.zip` bundles). Each pair’s
  `compare/` directory now includes `compare-report.html` plus a
  `compare-report_files/` folder containing the 2025 LVCompare image assets
  (set `COMPAREVI_REPORT_FORMAT=html-single` if you need the legacy single-file
  artifact).
- Labels: successful runs add `vi-staging-ready` (input configurable) and remove it automatically if staging fails or
  finds no pairs.
- Flag overrides: set repository variables `VI_STAGE_COMPARE_FLAGS_MODE` (defaults to `replace`), `VI_STAGE_COMPARE_FLAGS`
  (newline-separated list), and `VI_STAGE_COMPARE_REPLACE_FLAGS` to control LVCompare ignore bundles. Even when filters
  are configured, the workflow also runs an unsuppressed `full` pass so block diagram/front panel edits remain visible;
  both passes and their flag sets appear in the summary's **Flags** column.
- Smoke coverage: `node tools/npm/run-script.mjs smoke:vi-stage -- --DryRun` prints the plan;
  `node tools/npm/run-script.mjs smoke:vi-stage` pushes a scratch branch
  using the baked-in `fixtures/vi-attr` pair so every run produces deterministic LVCompare output.

### Automatic VI compare for fork pull requests

- The `VI Compare (Fork PR)` workflow runs on every pull request that targets `develop`, including forks. The helper
  uses a custom fetch action so the fork head commit is checked out safely, generates a diff manifest, stages pairs,
  runs LVCompare, and uploads compare reports for reviewers.
- The job is read-only (no pushes or release writes) and produces the same artifact layout as `/vi-stage`, giving
  reviewers deterministic bundles without manual staging. The workflow executes on the trusted self-hosted Windows
  runner (`self-hosted, Windows, X64`) so the same LVCompare install used in CI handles fork PRs.
- Manual `/vi-stage` and `/vi-history` dispatches accept a `fetch_depth` input (default `20`) when you need to pull a
  deeper history for local tests.
- `/vi-history` artifacts now include extracted preview assets under
  `tests/results/pr-vi-history/<target>/previews/history-image-*` plus
  `tests/results/pr-vi-history/<target>/vi-history-image-index.json`
  (`schema: pr-vi-history-image-index@v1`) for deterministic image lookup.
- The history summary/comment renderer adds a `### Mobile Preview` block that inlines a capped set of extracted images
  so reviewers can scan cosmetic changes on mobile without downloading artifacts first.
- Comment-size safety guards cap preview/image payload and apply markdown truncation when needed; the summarizer writes
  this state to totals (`previewImages`, `markdownTruncated`) and emits an explicit truncation note in the PR comment.
- `pr-vi-history-summary@v1` now carries additive per-pair rows under `pairTimeline[]`:
  `targetPath`, `baseRef`, `headRef`, `classification`, `diff`, `durationSeconds`, `previewStatus`, `reportPath`,
  `imageIndexPath`.
- Run-level KPI envelope (`kpi`) is additive and includes:
  `signalRecall`, `noisePrecisionMasscompile`, `previewCoverage`, `timingP50Seconds`, `timingP95Seconds`,
  `commentTruncated`, `truncationReason`.
- `tools/Test-PRVIHistorySmoke.ps1` now emits explicit hybrid gate policy metadata (`schema: vi-history-policy-gate@v1`):
  strict (`requireDiff=true`) violations are hard failures, while smoke (`requireDiff=false`) violations are recorded as
  non-blocking warnings for diagnostics.
- Smoke runs now emit benchmark artifacts under `tests/results/_agent/smoke/vi-history/benchmarks/`:
  - `vi-history-benchmark-*.json` (`schema: vi-history-benchmark@v1`)
  - `vi-history-benchmark-delta-*.json` (`schema: vi-history-benchmark-delta@v1`)
  - `vi-history-benchmark-delta-*.md` (PR/issue-ready KPI delta comment body)
- `tools/Test-PRVIHistorySmoke.ps1` can post KPI delta evidence comments automatically:
  - always to the synthetic PR (before cleanup)
  - optionally to an issue via `-EvidenceIssueNumber`
- To rehearse the fork flow locally, run `pwsh -File tools/Test-ForkSimulation.ps1` in three passes: `-DryRun` shows the
  steps, the default run opens a draft PR and validates the automatic compare job, and `-KeepBranch` preserves the
  scratch branch while the staging/history dispatches finish so you can inspect the artifacts.

## Optional inputs

| Input name | Default | Description |
| --- | --- | --- |
| `compare_depth` | `0` | Maximum commit pairs to evaluate (`0` = no limit) |
| `compare_modes` | `default` | Comma/semicolon list of compare modes (`default,attributes,front-panel`) |
| `compare_ignore_flags` | `none` | LVCompare ignore toggles (`none`, `default`, or comma-separated flags) |
| `compare_additional_flags` | _(empty)_ | Extra LVCompare switches (space-delimited) |
| `compare_fail_fast` | `false` | Stop after the first diff |
| `compare_fail_on_diff` | `false` | Fail the workflow when any diff is detected |
| `sample_id` | _(empty)_ | Optional concurrency key (advanced use) |
| `notify_issue` | _(empty)_ | Issue number to receive the summary table as a comment |

These inputs map directly onto the parameters in `tools/Compare-VIHistory.ps1`,
so advanced behaviour remains available without cluttering the default UX.

## Local helper

You can run the same compare logic locally:

```powershell
pwsh -NoLogo -NoProfile -File tools/Compare-VIHistory.ps1 `
  -TargetPath Fixtures/Loop.vi `
  -StartRef develop `
  -Detailed `
  -RenderReport
```

If LabVIEW/LVCompare is not available locally, point the helper at the bundled stub:

```powershell
pwsh -NoLogo -NoProfile -File tools/Compare-VIHistory.ps1 `
  -TargetPath fixtures/vi-stage/bd-cosmetic/Head.vi `
  -StartRef develop `
  -MaxSignalPairs 1 `
  -NoisePolicy collapse `
  -InvokeScriptPath tests/stubs/Invoke-LVCompare.stub.ps1 `
  -Detailed -RenderReport -KeepArtifactsOnNoDiff
```

For a quick summary without digging through JSON, run:

```powershell
pwsh -NoLogo -NoProfile -File tools/Inspect-HistorySignalStats.ps1 -Verbose
```

Before running with the real LabVIEW CLI, verify your setup:

```powershell
pwsh -NoLogo -NoProfile -File tools/Verify-LVCompareSetup.ps1 -ProbeCli
```

The helper now processes every reachable commit pair by default. Supply
`-MaxPairs <n>` when you need to cap the history for large or exploratory runs.
Pass `-IncludeMergeParents` to audit merge parents alongside the mainline; the
extra comparisons surface lineage metadata (parent index, branch head, depth)
so reports and manifests call out where each revision originated.
Signal-first helpers are built in: use `-MaxSignalPairs <n>` (default `2`) to
limit the number of surfaced signal diffs and `-NoisePolicy include|collapse|skip`
(default `collapse`) to decide whether cosmetic-only changes are emitted,
aggregated, or skipped entirely.

Artifacts are written under `tests/results/ref-compare/history/` using the same
schema as the workflow outputs.

## Local-first VI history acceleration

For repeated local VI-history turns on a developer workstation, this repository
now exposes four explicit runtime profiles:

- `proof` keeps the canonical runtime truth:
  `nationalinstruments/labview:2026q1-linux`
- `dev-fast` uses the local-only NI-derived acceleration image:
  `comparevi-vi-history-dev:local`
- `warm-dev` reuses a long-lived local Docker runtime on top of that same
  dev image to remove repeated container bootstrap cost
- `windows-mirror-proof` is the first Windows mirror plane:
  `nationalinstruments/labview:2026q1-windows`

The operating rule is strict:

- local acceleration is for refinement speed only
- release and CI still prove the canonical `proof` plane
- `windows-mirror-proof` is proof-only in this first slice; it is not a warm or
  accelerated lane
- `windows-mirror-proof` stays pinned to the canonical NI Windows image instead
  of allowing arbitrary image overrides
- `comparevi-tools` remains the non-LV/tools image and is not reused for the
  VI-history runtime

Build the local acceleration image once:

```powershell
node tools/npm/run-script.mjs history:local:build-dev-image
```

Run one cold local refinement turn against the mounted working tree:

```powershell
node tools/npm/run-script.mjs history:local:refine -- `
  -BaseVi fixtures/vi-attr/Base.vi `
  -HeadVi fixtures/vi-attr/Head.vi `
  -HistoryTargetPath fixtures/vi-attr/Head.vi
```

Run the same flow against the canonical proof image:

```powershell
node tools/npm/run-script.mjs history:local:proof -- `
  -BaseVi fixtures/vi-attr/Base.vi `
  -HeadVi fixtures/vi-attr/Head.vi `
  -HistoryTargetPath fixtures/vi-attr/Head.vi
```

Run the Windows mirror proof lane on a Windows host running Windows
containers:

```powershell
node tools/npm/run-script.mjs history:local:windows-mirror:proof -- `
  -BaseVi fixtures/vi-attr/Base.vi `
  -HeadVi fixtures/vi-attr/Head.vi `
  -HistoryTargetPath fixtures/vi-attr/Head.vi
```

This plane exists for early Windows-headless defect detection before any
host-native LabVIEW 2026 32-bit promotion work. It is intentionally not a
replacement for the canonical Linux `proof` plane.

Start and reuse the warm local runtime:

```powershell
node tools/npm/run-script.mjs history:local:warm-runtime -- `
  -RepoRoot . `
  -ResultsRoot tests/results/local-vi-history/warm-dev `
  -RuntimeDir tests/results/local-vi-history/runtime/warm-dev

pwsh -NoLogo -NoProfile -File tools/Invoke-VIHistoryLocalRefinement.ps1 `
  -Profile warm-dev `
  -BaseVi fixtures/vi-attr/Base.vi `
  -HeadVi fixtures/vi-attr/Head.vi `
  -HistoryTargetPath fixtures/vi-attr/Head.vi
```

When a warm runtime is already present, `warm-dev` now gates reuse on a fresh
heartbeat. If the existing container is stale, stopped, or running the wrong
image, the manager deterministically replaces it instead of blindly reusing it.
You can force that recovery check without starting a review turn:

```powershell
node tools/npm/run-script.mjs history:local:warm-runtime:reconcile -- `
  -RepoRoot . `
  -ResultsRoot tests/results/local-vi-history/warm-dev `
  -RuntimeDir tests/results/local-vi-history/runtime/warm-dev
```

The local refinement facade writes:

- `local-refinement.json` (`schema: comparevi/local-refinement@v1`)
- `local-refinement-benchmark.json`
  (`schema: comparevi/local-refinement-benchmark@v1`)

The unified local operator shell writes:

- `local-operator-session.json`
  (`schema: comparevi/local-operator-session@v1`)

Use it when one local command needs to compose the runtime plane with an
optional downstream review hook while keeping review-compiler ownership outside
this repository:

```powershell
node tools/npm/run-script.mjs history:local:operator:review -- `
  -RepoRoot . `
  -HistoryTargetPath fixtures/vi-attr/Head.vi `
  -ReviewCommandPath C:\dev\comparevi-history\scripts\Invoke-CompareVIHistoryLocalReview.ps1
```

The operator session records the local-refinement receipt, benchmark receipt,
optional warm-runtime artifacts, and any downstream review output paths that
the review hook publishes.

The warm runtime manager writes:

- `local-runtime-lease.json` (`schema: comparevi/local-runtime-lease@v1`)
- `local-runtime-state.json` (`schema: comparevi/local-runtime-state@v1`)
- `local-runtime-health.json` (`schema: comparevi/local-runtime-health@v1`)
- `local-runtime-heartbeat.json`

Benchmark receipts now select the intended sample classes:

- `proof-cold`
- `dev-fast-cold`
- `warm-dev-repeat`
- `windows-mirror-proof-cold`

These receipts are intentionally local-first. They allow `comparevi-history`
and downstream consumers to reuse the same runtime planes without changing the
review-bundle semantics or the canonical CI proof surface.

The first documented downstream consumer of that split is
`LabVIEW-Community-CI-CD/labview-icon-editor-demo`. Use
[docs/knowledgebase/CrossRepo-VIHistory.md](docs/knowledgebase/CrossRepo-VIHistory.md)
for the supported `comparevi-history` local-review/local-proof loop that
maintainers should run before opening a PR to `develop`.

When those consumers resolve the backend through an extracted `CompareVI.Tools`
bundle, prefer the exported module facade
`Invoke-CompareVIHistoryLocalRefinementFacade` over hard-coded script-path
invocation. When they need one composed local command surface, prefer
`Invoke-CompareVIHistoryLocalOperatorSessionFacade`.

For a quicker end-to-end loop:

- `scripts/Run-VIHistory.ps1` regenerates the history results, prints the
  enriched Markdown summary (including attribute coverage), surfaces the first
  commit pairs it processed, writes `tests/results/ref-compare/history/history-context.json`
  with commit metadata, and renders `tests/results/ref-compare/history/history-report.md`
  (plus `history-report.html` when `-HtmlReport`) so reviewers get a single document
  with author/date context, diff outcome, and relative links to the preserved LVCompare
  report and artifact directory whenever a difference is detected. If the
  renderer throws or is missing, the script falls back to a lightweight Markdown
  stub so downstream tooling still has a report to reference.
- `scripts/Dispatch-VIHistoryWorkflow.ps1` wraps `gh workflow run` and echoes
  the URL to the most recent run so you can follow progress immediately.

Need a quick, local verification of LVCompare/LabVIEWCLI behaviour? Use
`tools/Verify-LocalDiffSession.ps1`:

```powershell
# Stubbed run (no LabVIEW required)
pwsh -NoLogo -NoProfile -File tools/Verify-LocalDiffSession.ps1 `
  -BaseVi fixtures/vi-stage/bd-cosmetic/Base.vi `
  -HeadVi fixtures/vi-stage/bd-cosmetic/Head.vi `
  -UseStub -Mode duplicate-window -SentinelTtlSeconds 10
```

The helper writes summary JSON under `tests/results/_agent/local-diff/<timestamp>/`
and prints a one-line overview for each run (exit code, whether CLI was skipped,
suppression reason, and output directory). The summary JSON includes the captured
stdout/stderr snippets, sentinel path (when applicable), and snapshots of
LabVIEW/LVCompare/LabVIEWCLI processes before/after each invocation.

- Modes include `normal`, `cli-suppressed`, `git-context`, and `duplicate-window`
  so you can validate the environment and sentinel guards without waiting for CI.
- For quick iterations open the VS Code Tasks palette and run either
  **Local: Verify diff session (stub)** or **Local: Verify diff session (real)**. The
  real task will probe LVCompare/LabVIEWCLI and can be combined with the helper’s
  `-AutoConfig` switch (or run `tools/New-LVCompareConfig.ps1`) to scaffold a
  local `configs/labview-paths.local.json` automatically when the setup isn’t ready.

To bootstrap LVCompare/LabVIEWCLI paths, run:

```powershell
pwsh -NoLogo -NoProfile -File tools/New-LVCompareConfig.ps1 -Probe
```

The command discovers installed binaries, prompts for overrides (or pass
`-NonInteractive` to accept defaults), writes `configs/labview-paths.local.json`,
and optionally verifies the configuration with `Verify-LVCompareSetup.ps1 -ProbeCli`.
Verify-LocalDiffSession's `-AutoConfig` parameter uses the same helper when
`-ProbeSetup` fails.

The helper also maintains a `versions` map keyed by LabVIEW release and bitness.
Detection is automatic when the LabVIEW path resembles `LabVIEW 2024 (32-bit)`,
and you can override it with `-Version <year>` / `-Bitness 32|64` to register
multiple installs. Re-running with `-Force` merges additional version entries
instead of discarding existing ones, so the config can track several LabVIEW
installations side by side. Pass `-LabVIEWVersion` / `-LabVIEWBitness` to
`Verify-LocalDiffSession.ps1` (or select the new VS Code task prompts) if you
need the auto-config step to target a specific installation explicitly. The
helper always resolves the 64-bit shared LVCompare path
(`C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`)
so diff capture consistently uses the supported engine even when 32-bit
components are installed.
Pass `-Stateless` when calling `Verify-LocalDiffSession.ps1` if you want each
run to re-discover LVCompare/LabVIEWCLI and remove the auto-generated
`configs/labview-paths.local.json` afterwards (a VS Code task entry is available
for this mode as well).

Need to point the tools at non-default LabVIEW/LVCompare installs? Copy
`configs/labview-paths.sample.json` to `configs/labview-paths.json` and list any
custom paths under the `lvcompare` and `labview` arrays; the resolvers consult
those entries before falling back to environment variables and canonical Program
Files locations. Run commands with `-Verbose` if you need to inspect the
candidate list while debugging.

For quick iteration, call `tools/Run-LocalDiffSession.ps1` (or use the updated
VS Code tasks). The wrapper delegates to `Verify-LocalDiffSession.ps1`, then
copies the run output to `tests/results/_agent/local-diff/latest/` and zips the
same payload to `tests/results/_agent/local-diff/latest.zip` so reports,
captures, and CLI logs are immediately available after each run (the stub task
archives to `latest-stub/` / `latest-stub.zip`).
The helper now runs LVCompare with no ignore filters by default so the full
signal is captured; pass `-NoiseProfile legacy` (or use the “legacy noise” VS
Code task) to restore the previous suppression bundle
(`-noattr -nofp -nofppos -nobd -nobdcosm`) when you need a quieter diff.

## Release and compatibility

The backend release tag `vX.Y.Z` (or prerelease `vX.Y.Z-rc.N`) is the canonical
version for this repository. That one tag/version line governs the stable backend
surfaces:

- `comparevi-cli` release archives and `comparevi-cli version`
- `CompareVi.Shared` package version
- `CompareVI.Tools` bundle metadata and release asset pin

For `CompareVI.Tools`, pin the bundle by backend release tag plus
`SHA256SUMS.txt`. The embedded PowerShell module manifest is still useful for
inspection, but consumers should not treat `ModuleVersion` alone as the release
identity.

Stable support promise:

- stable backend tags publish the CLI archives, `CompareVi.Shared`, and the
  `CompareVI.Tools` bundle from the same source ref
- rc tags are preview/backend-validation tags and should not be treated as
  stable downstream pins unless explicitly called out

Facade coordination:

- `comparevi-history` is a separate repo with its own semver line
- a backend release here does not automatically imply a facade release there
- if the backend contract consumed by the facade changes, update the facade's
  pinned backend ref and cut a facade release separately after its smoke/release
  workflows pass

Tagged releases also publish a `CompareVI.Tools` zip bundle for cross-repo
module consumers. Compatibility expectations for that asset are strict:

- keep all extracted bundle files together from the same release tag
- verify the zip against the release `SHA256SUMS.txt`
- import `tools/CompareVI.Tools/CompareVI.Tools.psd1` from the extracted bundle
  instead of mixing helper files from multiple tags
- when a downstream repo uses hosted NI Linux diagnostics, resolve
  `tools/Run-NILinuxContainerCompare.ps1` from the extracted bundle root and
  keep its adjacent support scripts in place
- for single-container NI Linux smoke/bootstrap lanes, prefer the runner's
  runtime-injection surface (`-RuntimeInjectionScriptPath`,
  `-RuntimeInjectionEnv`, `-RuntimeInjectionMount`) or the explicit
  `-RuntimeBootstrapContractPath` `viHistory` block so config/dependency setup,
  repo-branch materialization, bounded sequential VI-history pair execution,
  and the compare invocation stay inside one container execution
- when the smoke lane is bound to a VI-history source branch, keep the
  `maxCommitCount` safeguard in the bootstrap contract so oversized branches
  fail before the container turns into a full-history sweep; budget divergence
  from `develop`, not the entire baseline history
