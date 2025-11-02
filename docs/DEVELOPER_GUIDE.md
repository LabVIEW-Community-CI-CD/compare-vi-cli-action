<!-- markdownlint-disable-next-line MD041 -->
# Developer Guide

Quick reference for building, testing, and releasing the LVCompare composite action.

## Testing

- **Unit tests** (no LabVIEW required)
  - `./Invoke-PesterTests.ps1`
  - `./Invoke-PesterTests.ps1 -TestsPath tests/Run-StagedLVCompare.Tests.ps1` (targeted staged-compare coverage)
  - `pwsh -File tools/Run-Pester.ps1`
- **Integration tests** (LabVIEW + LVCompare installed)
  - Set `LV_BASE_VI`, `LV_HEAD_VI`
  - `./Invoke-PesterTests.ps1 -IntegrationMode include`
- **Helpers**
  - `tools/Dev-Dashboard.ps1`
- **Icon Editor build pipeline**
  - `node tools/npm/run-script.mjs icon-editor:build` - runs the vendored LabVIEW Icon Editor build using the upstream PowerShell actions.
  - Requires LabVIEW 2021 SP1 (32-bit and 64-bit) and LabVIEW 2023 (64-bit). `Invoke-IconEditorBuild.ps1` now validates those installs via `Find-LabVIEWVersionExePath` and fails fast with a remediation hint when any executable is missing.
  - Need quick feedback without LabVIEW? Set `ICON_EDITOR_BUILD_MODE=simulate`
    (optionally `ICON_EDITOR_SIMULATION_FIXTURE` to override the default VIP)
    before invoking the workflow or `priority:validate`. The run will call
    `tools/icon-editor/Simulate-IconEditorBuild.ps1`, copy the committed fixture,
    and emit the same manifest + package-smoke summary expected from a full build.
    Clear the variable or set it back to `build` before release/sign-off runs so
    the real pipeline executes.
  - `pwsh -File tools/icon-editor/Update-IconEditorFixtureReport.ps1` refreshes the fixture report (generates the JSON snapshot and rewrites the section in `docs/ICON_EDITOR_PACKAGE.md`; pre-push guards that it stays current).
  - `npm run icon-editor:dev:on` / `npm run icon-editor:dev:off` toggle LabVIEW development mode using the vendored helpers (`Set_Development_Mode.ps1` / `RevertDevelopmentMode.ps1`) and persist the current state.
  - Validate uploads the `icon-editor-fixture-report` artifact (JSON + Markdown) on each run for stakeholders.
  - `npm run icon-editor:dev:assert:on` / `npm run icon-editor:dev:assert:off` validate the LabVIEW `LocalHost.LibraryPaths` token so you can confirm dev mode is actually enabled or disabled before continuing.
  - Multi-lane tooling:
    - **Source lane (2021 SP1, 32/64-bit)** – dev-mode toggles, VIPC apply/restore, lvlibp builds.
    - **Report lane (2025, 64-bit)** – LabVIEWCLI/HTML compare reports; requires the shared `LabVIEWCLI.exe`.
    - **Packaging lane (2021 SP1, 32-bit + VIPM)** – VI Package Manager builds; ensure VIPM is installed alongside 2021.
    - `npm run env:labview:check` prints the availability of each lane and surfaces missing prerequisites.
  - `g-cli.exe` is expected at `C:\Program Files\G-CLI\bin\g-cli.exe`. Use `configs/labview-paths.local.json` (`GCliExePath`) or set `GCLI_EXE_PATH` only when you need to override the default.
  - Artifacts land in `tests/results/_agent/icon-editor/` (manifest + packaged outputs). Dependency VIPCs (`runner_dependencies.vipc`) apply automatically unless you pass `-InstallDependencies:$false`; the helper mirrors the upstream Build.ps1 (dev-mode enable → apply VIPCs → build lvlibp (32/64) & rename → update VIPB metadata → build the VI package → restore dev mode). Add `-RunUnitTests` to execute the icon editor unit suite. The manifest records the dev-mode state (`developmentMode.*`) and lists both lvlibp + vip artifacts for audit.
  - Packaging now runs a lightweight smoke check (`tools/icon-editor/Test-IconEditorPackage.ps1`) against the emitted `.vip` files, writing `package-smoke-summary.json` and recording the results under `manifest.packageSmoke` so CI can flag structural regressions without rerunning VIPM.
- **Smoke tests**
  - `pwsh -File tools/Test-PRVIStagingSmoke.ps1 -DryRun`
    (planning pass; prints the branch/PR that would be created)
  - `npm run smoke:vi-stage` (full sweep; requires
    `GH_TOKEN`/`GITHUB_TOKEN` with push + workflow scopes)
  - `pwsh -File tools/Test-PRVIHistorySmoke.ps1 -DryRun`
    (plan the `/vi-history` entry-point smoke)
  - `pwsh -File tools/Test-PRVIHistorySmoke.ps1 -Scenario sequential -DryRun`
    (plan the sequential multi-category history smoke; steps defined in
    `fixtures/vi-history/sequential.json`)
  - `npm run smoke:vi-history` (full `/vi-history` dispatch; requires
    `GH_TOKEN`/`GITHUB_TOKEN` with repo + workflow scopes)
  - GitHub workflow "Smoke VI Staging" (`.github/workflows/vi-staging-smoke.yml`)
    - Trigger from the Actions UI or `gh workflow run vi-staging-smoke.yml`.
    - Runs on the repository's self-hosted Windows runner (`self-hosted, Windows, X64`)
      and exercises both staging and LVCompare end-to-end; no hosted option.
    - Inputs:
      - `keep_branch`: set to `true` when you want to inspect the synthetic scratch
        PR afterward; keep `false` for normal sweeps so the helper cleans up.
    - Requires `GH_TOKEN`/`GITHUB_TOKEN` with push + workflow scopes. Locally,
      populate `$env:GH_TOKEN` (for example from `C:\github_token.txt`) before
      running `tools/Test-PRVIStagingSmoke.ps1`.
    - Successful runs upload `tests/results/_agent/smoke/vi-stage/smoke-*.json`
      summaries and assert the scratch PR carries the `vi-staging-ready` label.
    - Scenario catalog (defined in `Get-VIStagingSmokeScenarios`):
      - `no-diff`: Copy `fixtures/vi-attr/Head.vi` onto `Base.vi` → match.
      - `vi2-diff`: Stage `tmp-commit-236ffab/{VI1,VI2}.vi` into `fixtures/vi-attr/{Base,Head}.vi` (block-diagram
        cosmetic) → diff.
      - `attr-diff`: Stage `fixtures/vi-attr/attr/{BaseAttr,HeadAttr}.vi` → diff.
      - `fp-cosmetic`: Stage `fixtures/vi-stage/fp-cosmetic/{Base,Head}.vi` (front-panel cosmetic tweak) → diff.
      - `connector-pane`: Stage `fixtures/vi-stage/connector-pane/{Base,Head}.vi` (connector assignment change) → diff.
      - `bd-cosmetic`: Stage `fixtures/vi-stage/bd-cosmetic/{Base,Head}.vi` (block-diagram cosmetic label) → diff.
      - `control-rename`: Stage `fixtures/vi-stage/control-rename/{Base,Head}.vi` (control rename) → diff.
      - `fp-window`: Stage `fixtures/vi-stage/fp-window/{Base,Head}.vi` (window sizing change) → diff.

      Treat these fixtures as read-only baselines—update them only when you intend
      to change the smoke matrix. The `/vi-stage` PR comment includes this table
      (via `tools/Summarize-VIStaging.ps1`) so reviewers can immediately see which
      categories (front panel, block diagram functional/cosmetic, VI attributes)
      triggered without downloading artifacts. Locally, run the helper against
      `vi-staging-compare.json` to preview the Markdown before you push.

      Reading the PR comment: the staging workflow drops the same table into the
      `/vi-stage` response. Green checkmarks indicate staged pairs; review the
      category columns (front panel, block diagram functional/cosmetic,
      VI attributes) to catch unexpected diffs without downloading artifacts.
      Follow the artifact links when you need to inspect compare reports in detail.

      Compare flags: the staging helper honours `VI_STAGE_COMPARE_FLAGS_MODE`
      (default `replace`) and `VI_STAGE_COMPARE_FLAGS` repository variables. The
      default `replace` mode clears the quiet bundle so LVCompare reports include
      VI Attribute differences. Set the mode to `append` to keep the quiet bundle,
      and provide newline-separated entries in `VI_STAGE_COMPARE_FLAGS` (for
      example `-nobd`) when you want to add explicit flags.
      `VI_STAGE_COMPARE_REPLACE_FLAGS` accepts `true`/`false` to override the mode
      for a single run when needed. Regardless of the filtered profile, the workflow
      also executes an unsuppressed `full` pass so block diagram/front panel edits
      are never hidden; both modes surface in the PR summary's **Flags** column.
      LVCompare reports now use the multi-file HTML layout (`compare-report.html`
      + `compare-report_files/`) so the 2025 CLI retains category headings and images.
      Set `COMPAREVI_REPORT_FORMAT=html-single` when you explicitly need the legacy
      single-file artifact.
    - Staged compare automation exposes runtime toggles for LVCompare execution:
      - `RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS` sets an upper bound (seconds) for each compare run.
      - `RUN_STAGED_LVCOMPARE_LEAK_CHECK` (`true`/`false`) toggles post-run leak collection.
      - `RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS` adds a post-run delay before the leak probe runs.
      Leak counts now appear in the staging Markdown table and PR comment so reviewers can see lingering
      LVCompare/LabVIEW processes without downloading the artifacts.

    - `pr-vi-staging.yml` now calls `tools/Summarize-VIStaging.ps1` after
      LVCompare finishes. The helper inspects `vi-staging-compare.json`, captures
      the categories surfaced in each compare report (front panel, block diagram
      functional/cosmetic, VI attributes), and emits both a Markdown table and
      JSON snapshot. The workflow drops that table directly into the PR comment,
      so reviewers see attribute/block diagram/front panel hits without
      downloading the artifacts. Locally reproduce the same summary with:

      ``powershell
      pwsh -File tools/Summarize-VIStaging.ps1 `
        -CompareJson vi-compare-artifacts/compare/vi-staging-compare.json `
        -MarkdownPath ./vi-staging-compare.md `
        -SummaryJsonPath ./vi-staging-compare-summary.json
      ``

    - `/vi-history` PR comments (or the `pr-vi-history.yml` workflow) reuse the same pattern for history diffs:
      1. `tools/Get-PRVIDiffManifest.ps1` enumerates VI changes between the PR base/head commits.
      2. `tools/Invoke-PRVIHistory.ps1` resolves the history helper once
        (works with repo-relative targets) and runs the compare suite per VI.
        The helper now walks every reachable commit pair by default; pass `-MaxPairs <n>` only when you need
        a deliberate cap (for example the history smoke script still uses `-MaxPairs 6` to keep the loop fast).
        Use `-MaxSignalPairs <n>` (default `2`) to limit how many signal diffs surface in a run and tune
        cosmetic churn via `-NoisePolicy include|collapse|skip` (default `collapse`).
        Artifacts land under `tests/results/pr-vi-history/` (aggregate manifest plus `history-report.{md,html}` per
        target). Enable `-Verbose` locally to see the resolved helper path and origin
         (base/head) for each target.
        When LabVIEW/LVCompare is unavailable, run the helper with
        `-InvokeScriptPath tests/stubs/Invoke-LVCompare.stub.ps1` to exercise the flow using the stubbed CLI.
        `tools/Inspect-HistorySignalStats.ps1` wraps the helper + stub and prints the signal/noise counts directly.
      3. `tools/Summarize-PRVIHistory.ps1` renders the PR table with change types, comparison/diff counts, and
         relative report paths so reviewers can triage without downloading the artifact bundle.
    - Override the history depth via the workflow_dispatch input `max_pairs` when you need a longer runway; otherwise
      accept the default for quick attribution. The workflow uploads the results directory as
      `pr-vi-history-<pr-number>.zip` for local inspection.
    - History runs now keep the full signal by default (no quiet bundle). Override the compare flags with repository or
      runner variables when you need to restore selective filters:
      - `PR_VI_HISTORY_COMPARE_FLAGS_MODE` / `VI_HISTORY_COMPARE_FLAGS_MODE` (values `replace` or `append`)
      - `PR_VI_HISTORY_COMPARE_FLAGS` / `VI_HISTORY_COMPARE_FLAGS` (newline-delimited flag list)
- `PR_VI_HISTORY_COMPARE_REPLACE_FLAGS` / `VI_HISTORY_COMPARE_REPLACE_FLAGS`
        (force replace/append for a single run)

## GitHub helper utilities

- `node tools/priority/github-helper.mjs sanitize --input issue-body.md --output issue-body.gh.txt`  
  Doubles backslashes and normalises line endings so literal sequences (for example `\t`, `\tools`) survive `gh issue create/edit`. Omit `--output` to print to STDOUT.
- `node tools/priority/github-helper.mjs snippet --issue 531 --prefix Fixes`  
  Emits an auto-link snippet (defaults to `Fixes #531`) you can drop into PR descriptions so GitHub auto-closes the issue.
- `node tools/priority/standing-priority-handoff.mjs [--dry-run] <next-issue>`  
  Removes the `standing-priority` label from the current issue (if any), applies it to `<next-issue>`, and re-runs the cache sync (`tools/priority/sync-standing-priority.mjs`). Use `--dry-run` to preview the actions without mutating labels.

```bash
node tools/npm/run-script.mjs build
node tools/npm/run-script.mjs generate:outputs
node tools/npm/run-script.mjs lint            # markdownlint + custom checks
./tools/PrePush-Checks.ps1  # actionlint, optional YAML round-trip
```

## Release checklist

1. Update `CHANGELOG.md`
2. Tag (semantic version, e.g. `v0.6.0`)
3. Push tag (release workflow auto-generates notes)
4. Update README usage examples to latest tag
5. Verify marketplace listing once published

## Branching model

- `develop` is the integration branch. All standing-priority work lands here via squash merges (linear history).
- `main` reflects the latest release. Use release branches to promote changes from `develop` to `main`.
- For standing-priority work, create `issue/<number>-<slug>` and merge back with squash once checks are green.
- When the standing-priority issue changes mid-flight, realign the branch name and PR head with  
  `npm run priority:branch:rename -- --issue <number>`. The helper derives the slug from the issue title, renames the
  local branch, pushes the new name to any remotes that carried the old branch, retargets the matching PR, and (unless
  you pass `--keep-remote`) deletes the stale remote ref.
- Use short-lived `feature/<slug>` branches when parallel threads are needed. Rebase on `develop` frequently and
  open PRs with `npm run priority:pr`.
- When preparing a release:
  1. Create `release/<version>` from `develop` with `npm run release:branch`. The helper bumps `package.json`,
     pushes the branch to your fork, and opens a PR targeting `main`. Use `npm run release:branch:dry`
     when you want to rehearse the flow without touching remotes.
  2. Finish release-only work on feature branches targeting `release/<version>`.
  3. Merge the release branch into `main`, create the draft release, then fast-forward `develop`
     with `npm run release:finalize -- <version>`. The helper fast-forwards `main`, creates a draft
     GitHub release, fast-forwards `develop`, and records metadata under `tests/results/_agent/release/`.
     Use `npm run release:finalize:dry` to rehearse the flow without pushing.
     - The finalize helper blocks if the release PR has pending or failing checks; set
       `RELEASE_FINALIZE_SKIP_CHECKS=1` (or `RELEASE_FINALIZE_ALLOW_MERGED=1` / `RELEASE_FINALIZE_ALLOW_DIRTY=1`)
       to override in emergencies.
     - If `main` and the release branch no longer share history (for example, after cutting over to a new repository
       baseline), rerun the helper with `RELEASE_FINALIZE_ALLOW_RESET=1` so it can reset `main` to the release tip and
       push with `--force-with-lease`. Leave the variable unset during normal releases so unintended history rewrites are blocked.
- When rehearsing feature branch work, use `npm run feature:branch:dry -- my-feature` and
  `npm run feature:finalize:dry -- my-feature` to simulate branch creation and finalization without touching remotes.
- Delete branches automatically after merging (GitHub setting) so the standing-priority flow starts clean each time.

## CI automation secrets

- `AUTO_APPROVE_TOKEN` - Personal access token (PAT) used by the `PR Auto-approve` workflow to submit an approval once
  the `Validate` workflow succeeds. The token must belong to an account with review rights on this repository. Grant the
  token the minimal scopes required (`public_repo` is sufficient for GitHub.com repos). When the secret is unset the
  workflow quietly skips auto-approval.
- `AUTO_APPROVE_LABEL` *(optional)* - When set, the auto-approval workflow only acts on PRs carrying this label. The
  default label is `auto-approve` if the secret is omitted. Set the secret to `none` to disable label gating.
- `AUTO_APPROVE_ALLOWED` *(optional)* - Comma-separated list of GitHub usernames permitted for auto-approval (e.g.,
  `svelderrainruiz,octocat`). If omitted, all authors are eligible.

### Release metadata

- Running the live helpers writes JSON snapshots under `tests/results/_agent/release/`:
  - `release-<tag>-branch.json` captures the release branch base, commits, and linked PR.
  - `release-<tag>-finalize.json` records the fast-forward results and the GitHub release draft.
- `priority:sync` surfaces the most recent artifact in the standing-priority step summary and exposes it to downstream
  automation via `snapshot.releaseArtifacts`.
- The release router now suggests `npm run release:finalize -- <version>` automatically when the latest branch artifact
  lacks a matching finalize record.

## Pull request & merge policy

- Branch protection requires a linear history: use the **Squash and merge** button (or rebase-and-merge) so no merge
  commits land on `develop`/`main`.
- Keep PRs focused and include the standing issue reference (`#<number>`) in the commit subject and PR description.
- Ensure required checks (`validate`, `fixtures`, `session-index`) are green before merging; rerun as needed.
- Run `npm run priority:policy` if you need to audit merge settings locally; the command also runs during
  `priority:handoff-tests` and fails when repo/branch policy drifts.
- Prefer opening PRs from your fork with `npm run priority:pr`; the helper ensures `origin` targets your fork (creating
  it via `gh repo fork` if needed), pushes the current branch, and calls
  `gh pr create --fill --repo <upstream> --base develop --head <fork>:branch`.
- Detailed enforcement notes (feature-branch guards, merge history workflow,
  merge queue parameters) live in
  [`docs/knowledgebase/FEATURE_BRANCH_POLICY.md`](./knowledgebase/FEATURE_BRANCH_POLICY.md).

## Dispatcher modules

- `scripts/Pester-Invoker.psm1` - per-file execution with crumbs (`pester-invoker/v1`)
- `scripts/Invoke-PesterSingleLoop.ps1` - outer loop runner (unit + integration)
- `scripts/Run-AutonomousIntegrationLoop.ps1` - latency/diff soak harness

## History automation helpers

- `scripts/Run-VIHistory.ps1` - regenerates the manual compare suite locally,
  verifies the target VI exists at the selected ref, and prints the Markdown
  summary (attribute coverage included) for issue comments. You can also call it
  via `npm run history:run -- -ViPath Fixtures/Loop.vi -StartRef HEAD`. Add `-MaxPairs <n>`
  when you intentionally need a cap. Use `-IncludeMergeParents` to traverse merge
  parents as well as the first-parent chain so local artifacts include the same
  lineage metadata the audit automation expects.
- `scripts/Dispatch-VIHistoryWorkflow.ps1` - wraps `gh workflow run` for
  `vi-compare-refs.yml`, echoes the latest run id/link, and records dispatch
  metadata under `tests/results/_agent/handoff/vi-history-run.json` for
  follow-up. Invoke with
  `npm run history:dispatch -- -ViPath Fixtures/Loop.vi -CompareRef develop -NotifyIssue 317`.
- VS Code tasks **VI History: Run local suite** and **VI History: Dispatch
  workflow** prompt for VI path/refs and route through the same scripts so
  editors can trigger the flow without remembering the parameters.

### LabVIEW / LVCompare path overrides

- On shared runners the canonical installs sit under `C:\Program Files`, but
  local setups may vary. Copy `configs/labview-paths.sample.json` to
  `configs/labview-paths.json` and list overrides under:
  - `lvcompare` array â€“ explicit `LVCompare.exe` locations; first match wins.
  - `labview` array â€“ candidate `LabVIEW.exe` paths (per version/bitness).
- Environment variables (`LVCOMPARE_PATH`, `LABVIEW_PATH`, etc.) still win, and
  the provider now writes verbose logs enumerating every candidate so you can
  troubleshoot missing installs quickly (`pwsh -v 5` to surface messages).

## Watch mode tips

``powershell
$env:WATCH_RESULTS_DIR = 'tests/results/_watch'
pwsh -File tools/Watch-Pester.ps1 -RunAllOnStart -ChangedOnly
``

Artifacts: `watch-last.json`, `watch-log.ndjson`. Dev Dashboard surfaces these along with
queue telemetry and stakeholder contacts.

## Handoff telemetry & auto-trim

``powershell
pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim
``

- Surfaces watcher status inline (alive, verifiedProcess, heartbeatFresh/Reason, needsTrim).
- Emits a compact JSON snapshot to `tests/results/_agent/handoff/watcher-telemetry.json` and, when in CI,
  appends a summary block to the step summary.
- Auto-trim policy: if `needsTrim=true`, watcher logs are trimmed to the last ~4000 lines when either
  `-AutoTrim` is passed or `HANDOFF_AUTOTRIM=1` is set. Dev watcher also trims on start.
- Trim thresholds: ~5MB per log file; only oversized logs are trimmed.
- See [`WATCHER_TELEMETRY_DX.md`](./WATCHER_TELEMETRY_DX.md) for automation response expectations.

## Quick verification

```powershell
./tools/Quick-VerifyCompare.ps1                # temp files
./tools/Quick-VerifyCompare.ps1 -Same          # identical path preview
./tools/Quick-VerifyCompare.ps1 -Base A.vi -Head B.vi
```

Preview LVCompare command without executing:

```powershell
pwsh -File scripts/CompareVI.ps1 `
  -Base VI1.vi `
  -Head VI2.vi `
  -LvCompareArgs "-nobdcosm" `
  -PreviewArgs
```

## References

- [`docs/INTEGRATION_RUNBOOK.md`](./INTEGRATION_RUNBOOK.md)
- [`docs/TESTING_PATTERNS.md`](./TESTING_PATTERNS.md)
- [`docs/SCHEMA_HELPER.md`](./SCHEMA_HELPER.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)

### Fork pull request automation

- Fork PRs targeting `develop` automatically run the **VI Compare (Fork PR)** workflow. The job checks out the head
  commit using the shared `fetch-pr-head` helper, stages the affected VIs, runs LVCompare on the self-hosted runner, and
  uploads artifacts identical to the `/vi-stage` workflow.
- `/vi-stage` and `/vi-history` commands remain available for both upstream and fork contributions. They now re-use the
  fetch helper so they can operate on fork heads safely.
- The **PR Auto-approve Label** workflow runs after Validate. When a PR targets `develop`, is not a fork or draft, its
  checks are green, and (optionally) the author is allowed, the workflow adds the auto-approve label automatically. If
  any condition fails, the label is removed.
- When the workflow skips a PR it emits structured outputs (`autoapprove_reason`, `autoapprove_checks`,
  `autoapprove_detail`) and `::notice::` messages (for example, merge conflicts or failing checks). Downstream
  automation can inspect those outputs to surface richer status or trigger follow-up actions.
- Auto-approve still requires `AUTO_APPROVE_TOKEN`, optional `AUTO_APPROVE_LABEL` (defaults to `auto-approve`), and
  optional `AUTO_APPROVE_ALLOWED`. The label lifecycle is now fully automated so contributors do not need to toggle it
  manually.
- Manual `/vi-stage` and `/vi-history` workflows accept an optional `fetch_depth` input (default `20`). Increase it when
  you need additional commit history before running compares.
- Use `tools/Test-ForkSimulation.ps1` when validating fork automation. Run it in three passes: `-DryRun` prints the
  plan, the default run pushes a scratch branch, opens a draft PR, and waits for the fork compare workflow, and adding
  `-KeepBranch` preserves the branch/PR after the staging and history dispatches complete for manual inspection.
- When testing fork scenarios locally, use the composite `.github/actions/fetch-pr-head` action to simulate
  `pull/<id>/head` checkouts before invoking the staging or history helpers.

