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
- **Icon editor scope boundary**
  - Icon editor development is no longer in scope for this repository.
  - The active icon editor codebase and runbooks live in
    `svelderrainruiz/labview-icon-editor`.
  - Keep icon-editor automation out of standing-priority work in this repo.
- **Smoke tests**
  - `pwsh -File tools/Test-PRVIStagingSmoke.ps1 -DryRun`
    (planning pass; prints the branch/PR that would be created)
  - `node tools/npm/run-script.mjs smoke:vi-stage` (full sweep; requires
    `GH_TOKEN`/`GITHUB_TOKEN` with push + workflow scopes)
  - `pwsh -File tools/Test-PRVIHistorySmoke.ps1 -DryRun`
    (plan the `/vi-history` entry-point smoke)
  - `pwsh -File tools/Test-PRVIHistorySmoke.ps1 -Scenario sequential -DryRun`
    (plan the sequential multi-category history smoke; steps defined in
    `fixtures/vi-history/sequential.json`)
  - `node tools/npm/run-script.mjs smoke:vi-history` (full `/vi-history` dispatch; requires
    `GH_TOKEN`/`GITHUB_TOKEN` with repo + workflow scopes)
  - GitHub workflow "Smoke VI Staging" (`.github/workflows/vi-staging-smoke.yml`)
    - Trigger from the Actions UI or `gh workflow run vi-staging-smoke.yml`.
    - Runs on the repository's self-hosted Windows runner (`self-hosted, Windows, X64`)
      and exercises both staging and LVCompare end-to-end; no hosted option.
    - Inputs:
      - `keep_branch`: set to `true` when you want to inspect the synthetic scratch
        PR afterward; keep `false` for normal sweeps so the helper cleans up.
    - Requires `GH_TOKEN`/`GITHUB_TOKEN` with push + workflow scopes. Locally,
      the repo helpers also honor `GH_TOKEN_FILE`, `GITHUB_TOKEN_FILE`, and the
      standard host token file fallback (`C:\github_token.txt` on Windows,
      `/mnt/c/github_token.txt` on non-Windows host planes), so explicit
      `$env:GH_TOKEN` export is only needed when you want to override that
      default resolution order.
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
      and `compare-report_files/`) so the 2025 CLI retains category headings and images.
      Set `COMPAREVI_REPORT_FORMAT=html-single` when you explicitly need the legacy
      single-file artifact.
    - Staged compare automation exposes runtime toggles for LVCompare execution:
      - `RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS` sets an upper bound (seconds) for each compare run.
      - `RUN_STAGED_LVCOMPARE_LEAK_CHECK` (`true`/`false`) toggles post-run leak collection.
      - `RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS` adds a post-run delay before the leak probe runs.
      Leak counts now appear in the staging Markdown table and PR comment so reviewers can see lingering
      LVCompare/LabVIEW processes without downloading the artifacts.

    - Staging summary tooling calls `tools/Summarize-VIStaging.ps1` after
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

    - Manual VI history analysis reuses the same pattern for history diffs:
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
        The summary contract now includes additive image metadata for report rendering:
      - target node `reportImages` (`enabled`, `indexPath`, `previewCount`, `previews[]`)
      - totals `previewImages` and `markdownTruncated` in `pr-vi-history-summary@v1`
      - per-pair rows under `pairTimeline[]`:
          `targetPath`, `baseRef`, `headRef`, `classification`, `diff`, `durationSeconds`,
          `previewStatus`, `reportPath`, `imageIndexPath`
      - run-level `kpi` envelope:
          `signalRecall`, `noisePrecisionMasscompile`, `previewCoverage`,
          `timingP50Seconds`, `timingP95Seconds`, `commentTruncated`, `truncationReason`
        Classification enum contract for `pairTimeline[].classification`:
      - `signal`
      - `noise-masscompile`
      - `noise-cosmetic`
      - `unknown`
        The same helper emits a `### Mobile Preview` section in the PR comment/summary markdown when previews are
        available, and writes extracted files to `tests/results/pr-vi-history/<target>/previews/` with index contract
        `pr-vi-history-image-index@v1`.
        The on-demand smoke harness (`tools/Test-PRVIHistorySmoke.ps1`) enforces hybrid gate policy:
      - strict targets (`requireDiff=true`) are hard-fail
      - smoke targets (`requireDiff=false`) are non-blocking warnings
      - summary output includes `Policy` (`vi-history-policy-gate@v1`) with separated strict failures and smoke warnings
        Smoke KPI artifacts are additive and emitted per run:
      - `tests/results/_agent/smoke/vi-history/benchmarks/vi-history-benchmark-*.json`
          (`schema: vi-history-benchmark@v1`)
      - `tests/results/_agent/smoke/vi-history/benchmarks/vi-history-benchmark-delta-*.json`
          (`schema: vi-history-benchmark-delta@v1`)
      - `tests/results/_agent/smoke/vi-history/benchmarks/vi-history-benchmark-delta-*.md`
          (PR/issue evidence comment body)
        Use `-EvidenceIssueNumber <n>` to mirror KPI delta comments to a tracking issue.
        Extractor toggles:
      - `PR_VI_HISTORY_EXTRACT_REPORT_IMAGES`
      - `VI_HISTORY_EXTRACT_REPORT_IMAGES`
    - Override history depth with `-MaxPairs` when you need a longer runway; otherwise accept
      the default for quick attribution.
    - History runs now keep the full signal by default (no quiet bundle). Override the compare flags with repository or
      runner variables when you need to restore selective filters:
      - `PR_VI_HISTORY_COMPARE_FLAGS_MODE` / `VI_HISTORY_COMPARE_FLAGS_MODE` (values `replace` or `append`)
      - `PR_VI_HISTORY_COMPARE_FLAGS` / `VI_HISTORY_COMPARE_FLAGS` (newline-delimited flag list)
- `PR_VI_HISTORY_COMPARE_REPLACE_FLAGS` / `VI_HISTORY_COMPARE_REPLACE_FLAGS`
        (force replace/append for a single run)

## GitHub helper utilities

- `node tools/priority/github-helper.mjs sanitize --input issue-body.md --output issue-body.gh.txt`  
  Doubles backslashes and normalises line endings so literal sequences (for example `\t`, `\tools`) survive
  `gh issue create/edit`. Omit `--output` to print to STDOUT.
- `pwsh -NoLogo -NoProfile -File tools/Post-IssueComment.ps1 -Issue <number> -BodyFile issue-comment.md`
  Posts GitHub issue comments through `--body-file` by default so multiline Markdown survives PowerShell and mixed
  Windows/WSL shells without backtick-escape drift.
- `pwsh -NoLogo -NoProfile -File tools/Post-PullRequestComment.ps1 -PullRequest <number> -Repo <owner/repo> -BodyFile pr-comment.md`
  Posts GitHub pull-request comments through `--body-file` by default so multiline Markdown survives PowerShell and
  mixed Windows/WSL shells without backtick-escape drift.
- `node tools/priority/github-helper.mjs snippet --issue 531 --prefix Fixes`  
  Emits an auto-link snippet (defaults to `Fixes #531`) you can drop into PR descriptions so GitHub auto-closes the issue.
- `node tools/npm/run-script.mjs priority:project:portfolio:apply -- --url <issue-or-pr-url> --use-config`  
  Adds the issue/PR to project `LabVIEW-Community-CI-CD#2` when missing, applies the tracked single-select portfolio
  fields, and writes `tests/results/_agent/project/portfolio-apply-report.json`. Live apply now uses a target-scoped
  lookup plus one batched single-select mutation instead of a full board scrape followed by per-field writes. The
  report also carries normalized built-in board metadata (`Type`, `Milestone`, `Reviewers`, linked PRs, parent issue,
  `Sub-issues progress`) so future agents can reason about intake state without a second `gh project item-list`
  scrape.
- `node tools/npm/run-script.mjs priority:artifact:download -- --repo <owner/repo> --run-id <id> --artifact <name>`  
  Downloads named workflow artifacts through the checked-in helper path instead of raw `gh run download`, writing a
  deterministic report at `tests/results/_agent/reviews/run-artifact-download.json` (or `--report <path>`). Use this
  during live triage when you need a machine-readable distinction between `policy-wrapper-rejected`,
  `artifact-not-found`, `artifact-expired`, and `auth-failed`. When `GITHUB_OUTPUT` or `GITHUB_STEP_SUMMARY` is
  available, the CLI also projects the same status, count, and failure-class surface into workflow-friendly outputs and
  step-summary lines.
- `node tools/npm/run-script.mjs priority:github:metadata:apply -- --url <issue-or-pr-url> ...`  
  Applies canonical GitHub metadata directly on the issue or PR: issue type, milestone, assignees, requested
  reviewers, parent issue, and sub-issue linkage. The helper writes
  `tests/results/_agent/issue/github-metadata-apply-report.json` and verifies the post-apply state against the
  projected target state. Use this when the issue/PR metadata itself is the source of truth; use the project helper
  only for board fields.
- `node tools/priority/standing-priority-handoff.mjs [--repo <owner/repo>] [--dry-run] <next-issue>`  
  Normalizes the current repository lane back to exactly one standing issue, using the repo-aware label set
  (`fork-standing-priority` first on fork lanes, `standing-priority` on upstream), removes legacy standing labels from
  non-target issues, and re-runs the cache sync (`tools/priority/sync-standing-priority.mjs`).
- `node tools/priority/standing-priority-handoff.mjs [--repo <owner/repo>] [--dry-run] --auto`  
  Lists all open issues in the current repository, excludes the currently labelled standing issue, auto-selects the
  next actionable development item deterministically, and then applies the same label normalization flow. Cadence alert
  issues are deprioritized when non-cadence development issues are available.
- Priority PR and Validate dispatch helpers now emit fork-lane provenance receipts under `tests/results/_agent/issue/`
  so later workers can recover the canonical issue, any mirrored fork issue, and the selected execution plane without
  reparsing branch names. See `docs/knowledgebase/FEATURE_BRANCH_POLICY.md` for the lane-identity vocabulary.
- Standing-priority repository resolution is owner-agnostic. Order:
  1. `GITHUB_REPOSITORY`
  2. git remotes (`upstream`, then `origin`)
  3. package repository metadata.
  Use `AGENT_PRIORITY_UPSTREAM_REPOSITORY=<owner/repo>` (or `AGENT_UPSTREAM_REPOSITORY`) when you need to force
  upstream lookup in deforked or custom-remote environments.

```bash
node tools/npm/run-script.mjs build
node tools/npm/run-script.mjs generate:outputs
node tools/npm/run-script.mjs lint            # markdownlint + custom checks
node tools/npm/run-script.mjs priority:security:audit        # dependency-audit receipt (observe mode)
node tools/npm/run-script.mjs priority:security:audit:gate   # explicit blocking dependency-audit gate
./tools/PrePush-Checks.ps1  # actionlint, dependency-audit observation, optional YAML round-trip
```

The dependency-audit receipt now records a deterministic `packageState` block,
including `package.json` / `package-lock.json` hashes and a
`fingerprintSha256` so vulnerability changes can be tied back to the exact
audited Node dependency graph.

For Docker/Desktop VI history validation, run fast-loop lanes explicitly:

- Single-lane strict (recommended before full loop):
  - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope linux -StepTimeoutSeconds 600`
  - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope windows -StepTimeoutSeconds 600`
- Full dual-lane loop:
  - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope both -StepTimeoutSeconds 600`
- Native LabVIEW 2026 host split diagnostics:
  - `node tools/npm/run-script.mjs env:labview:2026:host-planes`
  - The Windows host is treated as the execution runner; the generated report records `runner.hostIsRunner=true`.
  - The helper writes both:
    - `labview-2026-host-plane-report.json`
    - `labview-2026-host-plane-summary.md`
  - GitHub output keys include:
    - `labview-2026-host-plane-report-path`
    - `labview-2026-host-plane-summary-path`
  - Use `docs/SINGLE_HOST_LABVIEW_2026_PLANES.md` when you need the explicit four-plane operating model and the
    authoritative replay/diagnostics entry points in one place.
- Differentiated history readback:
  - `node tools/npm/run-script.mjs history:diagnostics:show -- --ResultsRoot tests/results/local-parity/windows`
  - The replay prints the host/runner plane split before the differentiated mode diagnostics.
  - When readiness provenance is present, the replay also prints:
    - host-plane summary path
    - summary status
    - summary SHA-256
- Stable operator-facing loop labels:
  - `linux-docker-fast-loop`
  - `windows-docker-fast-loop`
  - `dual-docker-fast-loop`
- `-ManageDockerEngine` is permitted only when `-LaneScope both`.
- Fast-loop provenance surfaces:
  - `tools/Test-DockerDesktopFastLoop.ps1` emits:
    - `docker-fast-loop-summary-path`
    - `docker-fast-loop-status-path`
    - `docker-fast-loop-host-plane-summary-path`
    - `docker-fast-loop-host-plane-summary-status`
    - `docker-fast-loop-host-plane-summary-sha256`
    - `docker-fast-loop-host-plane-summary-reason`
    - and, when `-StepSummaryPath` is supplied, appends a `Docker Fast Loop Summary` block carrying the same
      summary/status/host-plane provenance plus the fail-closed reason surface
  - `tools/Write-DockerFastLoopReadiness.ps1` carries `hostPlaneSummary.path|status|sha256|reason`
  - `tools/Write-DockerFastLoopProof.ps1` emits:
    - `docker-fast-loop-proof-host-plane-summary-path`
    - `docker-fast-loop-proof-host-plane-summary-sha256`
  - treat missing declared host-plane summary artifacts as fail-closed contract violations

## Runtime daemon

- The portable observer loop remains Linux-only. On this Windows workspace, run it through the existing Docker/Linux
  path rather than invoking `tools/priority/runtime-daemon.mjs` directly.
- `node tools/priority/runtime-daemon.mjs --repo <owner/repo> --stop-on-idle --execute-turn`
  enables the unattended execution seam:
  - planner prefers live standing-priority state for the target repo
  - the loop exits cleanly when no actionable work remains
  - compare-vi fork mirrors can be closed and advanced deterministically
  - cadence-only standing issues stop the loop instead of spinning
- For fork-drain runs, point `--repo` at the fork queue you want to drain and set
  `AGENT_PRIORITY_UPSTREAM_REPOSITORY=<upstream-owner/repo>` when the canonical upstream differs from the target repo.

## Release checklist

1. Update `CHANGELOG.md`
2. Tag (semantic version, e.g. `v0.6.0`)
3. Push tag (release workflow auto-generates notes)
4. Update README usage examples to latest tag
5. Verify marketplace listing once published

## Branching model

- `develop` is the integration branch. All standing-priority work lands here via squash merges (linear history).
- `main` reflects the latest release. Use release branches to promote changes from `develop` to `main`.
- For standing-priority work, create the plane-appropriate lane branch and merge back with squash once checks are green:
  - `issue/personal-<number>-<slug>` for the personal authoring plane
  - `issue/origin-<number>-<slug>` for the org-fork review plane
  - bare `issue/<number>-<slug>` only for upstream-native lanes
  The canonical mapping lives in [BRANCH_ROLE_CONTRACT.md](BRANCH_ROLE_CONTRACT.md).
- When the standing-priority issue changes mid-flight, realign the branch name and PR head with  
  `node tools/npm/run-script.mjs priority:branch:rename -- --issue <number>`. The helper derives the slug from the
  issue title, renames the local branch, pushes the new name to any remotes that carried the old branch, retargets the
  matching PR, and (unless you pass `--keep-remote`) deletes the stale remote ref.
- Use short-lived `feature/<slug>` branches when parallel threads are needed. Rebase on `develop` frequently and
  open PRs with `node tools/npm/run-script.mjs priority:pr`.
- When preparing a release:
  1. Create `release/<version>` from `develop` with `node tools/npm/run-script.mjs release:branch`. The helper bumps `package.json`,
    pushes the branch to your fork, and opens a PR targeting `main`. Use `node tools/npm/run-script.mjs release:branch:dry`
     when you want to rehearse the flow without touching remotes.
  2. Finish release-only work on feature branches targeting `release/<version>`.
  3. Merge the release branch into `main`, create the draft release, then fast-forward `develop`
     with `node tools/npm/run-script.mjs release:finalize -- <version>`. The helper fast-forwards `main`, creates a
     draft GitHub release, fast-forwards `develop`, and records metadata under `tests/results/_agent/release/`.
     Use `node tools/npm/run-script.mjs release:finalize:dry` to rehearse the flow without pushing.
     - Finalize now requires the release branch metadata artifact (`release-<tag>-branch.json`) to be present before it
       cuts a draft tag, and it verifies both branch/finalize artifacts are retained under
        `tests/results/_agent/release/`.
     - The finalize helper blocks if the release PR has pending or failing checks; set
       `RELEASE_FINALIZE_SKIP_CHECKS=1` (or `RELEASE_FINALIZE_ALLOW_MERGED=1` / `RELEASE_FINALIZE_ALLOW_DIRTY=1`) to
       override in emergencies.
     - If `main` and the release branch no longer share history (for example, after cutting over to a new repository
       baseline), rerun the helper with `RELEASE_FINALIZE_ALLOW_RESET=1` so it can reset `main` to the release tip and
       push with `--force-with-lease`. Leave the variable unset during normal releases so unintended history rewrites
       are blocked.
- When rehearsing feature branch work, use `node tools/npm/run-script.mjs feature:branch:dry -- my-feature` and
  `node tools/npm/run-script.mjs feature:finalize:dry -- my-feature` to simulate branch creation and finalization
  without touching remotes.
- Delete branches automatically after merging (GitHub setting) so the standing-priority flow starts clean each time.

## Deployment approval gates

- Standard pull-request and merge-queue `Validate` runs are machine-gated only and do not target a protected
  environment.
- Tag releases use the GitHub Actions `production` environment (see `Release on tag / release`).
- Monthly stability dispatch approvals use the `monthly-stability-release` environment gate.
- Configure required reviewers in GitHub environment settings so deployment acknowledgement is explicit and review
  requests can be approved through GitHub web/mobile:
  Settings -> Environments -> `production` / `monthly-stability-release` -> Required reviewers.
- Run `node tools/npm/run-script.mjs priority:deployment:gate-policy` to verify the protected promotion environments enforce
  required reviewers and admin-bypass policy; report path:
  `tests/results/_agent/deployments/environment-gate-policy.json`.
- Run `node tools/npm/run-script.mjs priority:deployment:gate-sync -- --target origin --target personal` to dry-run fork
  environment parity from the checked-in portability policy. Add `--apply` only when you intend to create or repair the
  fork environments through the repo-native helper path.
- `PR Auto-approve` and `PR Auto-approve Label` workflows were retired because branch policy requires `0` approvals.

### Release metadata

- Running the live helpers writes JSON snapshots under `tests/results/_agent/release/`:
  - `release-<tag>-branch.json` captures the release branch base, commits, and linked PR.
  - `release-<tag>-finalize.json` records the fast-forward results and the GitHub release draft.
- `release:finalize` now blocks when release hygiene evidence is not clean:
  - requires `tests/results/session-index.json` with `status=ok` and zero failed/error counts.
  - runs `tools/Detect-RogueLV.ps1` and blocks if rogue LabVIEW/LVCompare processes are detected.
  - set `RELEASE_FINALIZE_SKIP_HYGIENE=1` only for emergency operator overrides.
- `release:finalize` also blocks when pre-tag compare evidence is incomplete:
  - requires latest successful `vi-compare-refs.yml` and `vi-staging-smoke.yml` runs for the release branch.
  - requires both runs to publish artifacts (manifest/staging bundles) before tag cut.
  - set `RELEASE_FINALIZE_SKIP_COMPARE_EVIDENCE=1` only for emergency operator overrides.
- `release:finalize` validates required release PR contexts from `tools/policy/branch-required-checks.json`
  (`release/*`) and blocks on missing/pending/failing required checks.
- `release:finalize` enforces standing-priority and parity evidence before tag cut:
  - requires current standing-priority artifacts (`.agent_priority_cache.json`,
    `tests/results/_agent/issue/router.json`, `tests/results/_agent/issue/<issue>.json`)
    to match the live standing issue.
  - enforces origin/upstream parity KPI `tipDiff.fileCount == 0` (default refs:
    `upstream/develop` vs `origin/develop`).
  - optional overrides: `RELEASE_FINALIZE_SKIP_PRIORITY_PARITY=1`,
    `RELEASE_PARITY_BASE_REF`, `RELEASE_PARITY_HEAD_REF`,
    `RELEASE_PARITY_TIP_DIFF_TARGET`.
- `tools/priority/verify-release-branch.mjs` enforces release-doc consistency before tag cut by requiring
  `docs/release/PR_NOTES.md`, `docs/release/TAG_PREP_CHECKLIST.md`, and
  `docs/archive/releases/RELEASE_NOTES_<tag>.md` to reference the current release tag.
  It also requires both `package.json` and `CHANGELOG.md` to change relative to the configured release base ref.
- `tools/priority/validate-semver.mjs` now performs branch-aware integrity checks: on `release/<tag>` heads it enforces
  `package.json` SemVer parity with the branch tag.
- `priority:sync` surfaces the most recent artifact in the standing-priority step summary and exposes it to downstream
  automation via `snapshot.releaseArtifacts`.
- `priority:parity` reports origin/upstream parity using two metrics:
  - `tipDiff.fileCount` from `git diff --name-only upstream/develop origin/develop` (primary KPI; `0` means tip parity)
  - commit divergence from `git rev-list --left-right --count upstream/develop...origin/develop` (telemetry only)
- Validate `session-index` now embeds parity telemetry under `runContext.parity` and appends an
  `Origin/Upstream Parity Telemetry` block to the step summary.
- The release router now suggests `node tools/npm/run-script.mjs release:finalize -- <version>` automatically when the
  latest branch artifact lacks a matching finalize record.

## Pull request & merge policy

- Branch protection requires a linear history: use the **Squash and merge** button (or rebase-and-merge) so no merge
  commits land on `develop`/`main`.
- Keep PRs focused and include the standing issue reference (`#<number>`) in the commit subject and PR description.
- Ensure required checks (`validate`, `fixtures`, `session-index`) are green before merging; rerun as needed.
- `Validate` now computes a `validate-scope-plan` artifact before the heavy lanes fan out.
  Standard `pull_request` and `merge_group` runs classify changed paths with an allow-list into:
  `docs-metadata-only`, `tests-only`, `tools-policy-only`, `ci-control-plane`, `mixed-lightweight`, `compare-engine-history`,
  `docker-vi-history`, plus conservative fallbacks (`mixed-runtime`, `unclassified`).
  Manual `workflow_dispatch` stays explicit (`manual-full`) and `push` keeps the default post-merge full validation shape.
- Scoped skip surfaces:
  Required checks stay deterministic: `fixtures` and `vi-history-scenarios-linux` still report status for lightweight
  scopes, but their expensive steps no-op when routing says the lane is out of scope.
  `fixtures` heavy work only runs for `compare-engine-history`, `mixed-runtime`, `unclassified`, and explicit
  full-validation modes.
  `comparevi-history-bundle-certification` follows the same routing.
  `vi-history-scenarios-*` runs for `compare-engine-history`, `docker-vi-history`, `mixed-runtime`, `unclassified`, and
  explicit manual dispatches; the final VI-history plan still honors `history_scenario_set`.
- Hosted Windows mirror proof now lives in `Validate` as the non-required `vi-history-scenarios-windows` lane.
  That lane runs on GitHub-hosted `windows-2022`, hydrates
  `nationalinstruments/labview:2026q1-windows` with no repository runner dependency, and is expected to
  take materially longer to pull than the Linux lane.
- If the hosted Windows runner cannot expose a Docker Windows daemon, the lane records
  `windows_host_preflight_status = unavailable` and skips the heavy compare instead of poisoning
  the current queue item with a non-required proof failure.
  Agents can dispatch the hosted lane while continuing with the manual Linux or Windows Docker Desktop/WSL2 lanes locally.
- `node tools/npm/run-script.mjs priority:lane:concurrency:plan` now reads the host-plane report, host RAM budget,
  and optional Docker runtime snapshot to recommend a safe concurrent hosted/manual bundle before those lanes are
  dispatched.
- Machine-readable routing evidence is written to
  `tests/results/_agent/validate-scope-plan/validate-scope-plan.json` and summarized in the Validate step summary so
  reviewers can see why heavy lanes were bypassed.
- GitHub-native automatic Copilot review is intentionally disabled for this repository. Draft review is acquired through
  the local CLI/orchestrator path, and `ready_for_review` is reserved for final hosted validation on the current head.
- `agent-review-policy` is the hosted concentrator for local review evidence and promotion validation. It should not be
  used to acquire a second GitHub-side Copilot review after `ready_for_review`.
- Run `node tools/npm/run-script.mjs priority:policy` (or `node tools/npm/run-script.mjs priority:policy:sync`) if you
  need to audit merge settings locally; the command also runs during `priority:handoff-tests` and fails when
  repo/branch policy drifts.
- Capture live branch/ruleset evidence with `node tools/npm/run-script.mjs priority:policy:snapshot`; the snapshot is
  written to `tests/results/_agent/policy/policy-state-snapshot.json`.
  Inspect `state.copilotReview` in that artifact to confirm rulesets do not contain `copilot_code_review` rules.
  Repository-level "Automatic request Copilot review" remains a manual settings-page verification point because GitHub's
  REST policy surfaces do not expose that toggle directly.
- Run `node tools/npm/run-script.mjs priority:queue:supervisor -- --dry-run` to preview queue ordering and
  candidate gates, or add `--apply` for guarded autonomous enqueue mode.
  Use `--governor-state <path>` (default `tests/results/_agent/slo/ops-governor-state.json`) to
  enforce SLO governor mode-switches (`normal|stabilize|pause`) before enqueue actions.
  Use `node tools/npm/run-script.mjs priority:queue:readiness` to materialize the ranked ready-set report
  (`tests/results/_agent/queue/queue-readiness-report.json`) from the latest supervisor snapshot.
  The hosted queue-supervisor workflow runs every 5 minutes and also on `workflow_run` completion for
  `Validate`/`Policy Guard (Upstream)` on `develop` so queue refill latency stays low.
  Throughput controls:
  - `QUEUE_AUTOPILOT_MAX_INFLIGHT` / `--max-inflight` sets the queue target cap.
  - `QUEUE_AUTOPILOT_ADAPTIVE_CAP` (default `1`) and `QUEUE_AUTOPILOT_MIN_INFLIGHT` / `--min-inflight` enable
    adaptive throttling when runtime pressure or trunk-health degradation is detected.
  - `QUEUE_BURST_MODE` / `--burst-mode` (`auto|on|off`) and
    `QUEUE_BURST_REFILL_CYCLES` / `--burst-refill-cycles` control release burst behavior.
    Auto mode activates on release windows, open `release/*` PRs, or `release-burst` labels, and backs off for
    30 minutes whenever the throughput controller enters `stabilize`.
  For queue-aware release proposals, run `node tools/npm/run-script.mjs priority:release:conductor -- --dry-run`.
  Apply mode requires `RELEASE_CONDUCTOR_ENABLED=1`; if signing material is unavailable, the conductor remains
  proposal-only and emits evidence without mutating tags.
  Hosted `schedule` and `workflow_run` conductor lanes stay proposal-only when apply mode is disabled, and dry-runs
  record advisory-only queue-evidence / no-recent-success diagnostics instead of failing for missing queue artifacts or
  idle dwell windows.
  Use `node tools/npm/run-script.mjs priority:remediation:slo` to compute remediation SLO governance metrics
  (MTTD, route latency, MTTR by priority, reopen rate, queue/trunk/release signals) and emit
  `tests/results/_agent/slo/remediation-slo-report.json` plus governor state
  `tests/results/_agent/slo/ops-governor-state.json` (`ops-governor-state@v1`).
  The governor artifact includes transition reasons and operator recovery notes used by queue-supervisor pause hooks.
  Use `node tools/npm/run-script.mjs priority:weekly:scorecard` to build the weekly governance snapshot at
  `tests/results/_agent/slo/weekly-scorecard.json` (optionally with `--route-on-persistent-breach`).
  The `Weekly Governance Scorecard` workflow (`.github/workflows/weekly-scorecard.yml`) runs weekly and auto-switches
  to `gameday` mode on the first Wednesday UTC to replay canary + scorecard governance in one lane.
- For deterministic incident routing, run the control-plane chain in order:
  - `node tools/npm/run-script.mjs priority:event:ingest -- ...`
  - `node tools/npm/run-script.mjs priority:policy:route -- --event <event-report-or-event-json>`
  - `node tools/npm/run-script.mjs priority:issue:route -- --decision tests/results/_agent/ops/policy-decision-report.json`
  - `node tools/npm/run-script.mjs priority:decision:ledger -- append --decision tests/results/_agent/ops/policy-decision-report.json`
  - `node tools/npm/run-script.mjs priority:decision:ledger -- replay --sequence <n>`
  The router dedupes by incident fingerprint marker and emits
  `tests/results/_agent/ops/issue-routing-report.json` (`priority/issue-routing-report@v1`).
  The decision ledger is append-only (`ops-decision-ledger@v1`) at
  `tests/results/_agent/ops/ops-decision-ledger.json` with replay output under
  `tests/results/_agent/ops/ops-decision-replay.json`.
  For canary replay conformance (single/repeated/reordered fixtures with deterministic dedupe assertions), run
  `node tools/npm/run-script.mjs priority:canary:replay`; this emits
  `tests/results/_agent/canary/canary-replay-conformance-report.json`
  (`priority/canary-replay-conformance-report@v1`).
- For defork-safe bootstrap in a fresh repository context, run
  `node tools/npm/run-script.mjs priority:contracts:bootstrap` to initialize required queue/standing labels and
  execute policy contract verification (`--apply-policy` applies branch/ruleset policy; `--dry-run` previews only).
- In unattended flows, use lane-enforced standing sync (`node tools/npm/run-script.mjs priority:sync:lane`) so
  missing or duplicate standing-priority labels fail fast and emit deterministic diagnostics:
  - `tests/results/_agent/issue/no-standing-priority.json`
  - `tests/results/_agent/issue/multiple-standing-priority.json`
  When the repository has zero open issues, the no-standing report now records
  `reason = queue-empty` plus `openIssueCount = 0`; that is an idle-repository
  state, not label drift, so bootstrap and lane sync should complete without
  forcing a synthetic standing issue.
  By default, sync does not create `.agent_priority_cache.json` on fresh clones; pass
  `--materialize-cache` (or set `AGENT_PRIORITY_MATERIALIZE_CACHE=1`) when you explicitly want cache materialization.
- Enforce milestone hygiene for `standing-priority` / `program` / `[P0|P1]` issues with
  `node tools/npm/run-script.mjs priority:milestone:hygiene -- --repo <owner/repo>`.
  Use `--apply-default-milestone --default-milestone <title>` for reconciliation and add
  `--create-default-milestone --default-milestone-due-on <iso-8601>` when the default
  milestone does not exist yet.
- Use strict verification (`node tools/priority/check-policy.mjs --fail-on-skip`) when you need token/permission skips to
  fail deterministically (for example in upstream policy guard workflows).
- Policy guard workflows resolve token candidates with
  `tools/priority/Resolve-PolicyToken.ps1` and require an admin-capable token source. If policy guard fails with
  `Authorization unavailable` or `authenticated-no-admin`, rotate `GH_TOKEN`/`GITHUB_TOKEN` secrets in upstream. For
  Dependabot-triggered runs, seed `GH_TOKEN` in Dependabot secret scope as well:
  `gh secret set GH_TOKEN --repo <owner/repo> --app dependabot`.
- Use `node tools/npm/run-script.mjs priority:policy:apply` only with admin token scope when you intentionally need to
  sync GitHub protections/rulesets back to `tools/priority/policy.json`.
- Run `node tools/npm/run-script.mjs priority:commit-integrity -- --pr <number>` to evaluate commit trust posture
  locally. Add `--observe-only` to mirror staged rollout mode. See `docs/COMMIT_INTEGRITY_CHECK.md` for full contract
  and rollout flags (`COMMIT_INTEGRITY_ENFORCE`).
- Prefer opening PRs from your fork with `node tools/npm/run-script.mjs priority:pr`; the helper respects
  `AGENT_PRIORITY_ACTIVE_FORK_REMOTE` (or `--head-remote origin|personal`) so future agents can open upstream PRs from
  either the org fork or the personal fork without changing clones. User-owned forks still flow through
  `gh pr create`; same-owner renamed forks switch to GitHub GraphQL `createPullRequest` with `headRepositoryId`, so
  agents do not need to mirror branches back to upstream just to create the PR.
- Use `node tools/npm/run-script.mjs priority:issue:mirror -- --issue <number> --fork-remote origin|personal` to
  materialize or refresh a fork-lane mirror issue. The helper writes a machine-readable upstream pointer comment into
  the fork issue body so bootstrap can route locally while PR helpers still close the upstream issue.
- The machine-readable GitHub intake source of truth lives in
  `tools/priority/github-intake-catalog.json`. Use
  `pwsh -File tools/Resolve-GitHubIntakeRoute.ps1 -ListScenarios` or
  `pwsh -File tools/Resolve-GitHubIntakeRoute.ps1 -Scenario <name>` to choose
  the supported issue/PR path before drafting custom Markdown.
- For the higher-level scenario facade, use
  `pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario <name> -OutputPath <body-file>`
  to render the correct issue or PR body from the catalog before invoking
  `gh issue create` / `node tools/npm/run-script.mjs priority:pr`. For PR scenarios, the helper can hydrate
  issue title/URL and standing-priority state from the existing issue snapshot
  under `tests/results/_agent/issue/`.
- For issue comments with multiline Markdown, use
  `pwsh -File tools/Post-IssueComment.ps1 -Issue <number> -BodyFile issue-comment.md`
  (or `-Body <text>` when the caller already has the rendered markdown in memory) instead of inline
  `gh issue comment --body "..."`.
- For a machine-readable execution planner and explicit apply helper, use
  `pwsh -File tools/Invoke-GitHubIntakeScenario.ps1 -Scenario <name> -AsJson`.
  This stays in dry-run mode by default, emits the structured execution plan,
  and only mutates GitHub when you add `-Apply`. Pass `-HeadRemote origin|personal`
  (and `-ForkRemote ...` for branch orchestration scenarios) when the plan needs
  to target a specific fork without first mirroring the branch upstream.
- For the whole-surface report, use `pwsh -File tools/Write-GitHubIntakeAtlas.ps1`;
  it emits Markdown + JSON intake atlas artifacts under
  `tests/results/_agent/intake/`.
- When you need the repository's richer intake metadata blocks and template variants, prefer
  `pwsh -File tools/Branch-Orchestrator.ps1 -Issue <number> -Execute [-PRTemplate <variant>]` or
  `pwsh -File tools/New-PullRequestBody.ps1 ... -OutputPath pr-body.md` plus
  `node tools/npm/run-script.mjs priority:pr -- --issue <number> --repo <owner/repo> --branch <branch> --base <base>
  --title <title> --body-file pr-body.md`.
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
  via `node tools/npm/run-script.mjs history:run -- -ViPath Fixtures/Loop.vi -StartRef HEAD`. Add `-MaxPairs <n>`
  when you intentionally need a cap. Use `-IncludeMergeParents` to traverse merge
  parents as well as the first-parent chain so local artifacts include the same
  lineage metadata the audit automation expects.
- `scripts/Dispatch-VIHistoryWorkflow.ps1` - wraps `gh workflow run` for
  `vi-compare-refs.yml`, echoes the latest run id/link, and records dispatch
  metadata under `tests/results/_agent/handoff/vi-history-run.json` for
  follow-up. Invoke with
  `node tools/npm/run-script.mjs history:dispatch -- -ViPath Fixtures/Loop.vi -CompareRef develop -NotifyIssue 317`.
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
- Carries forward watcher runtime-event metadata (`events.path`, `events.count`, `events.lastEventAt`)
  so downstream tools can inspect `watcher-events.ndjson` directly.
- Emits a compact JSON snapshot to `tests/results/_agent/handoff/watcher-telemetry.json` and, when in CI,
  appends a summary block to the step summary.
- Refreshes `tests/results/_agent/handoff/entrypoint-status.json` so the
  standard handoff command also writes the canonical machine-readable entrypoint
  index for future agents.
- Auto-trim policy: if `needsTrim=true`, watcher logs are trimmed to the last ~4000 lines when either
  `-AutoTrim` is passed or `HANDOFF_AUTOTRIM=1` is set. Dev watcher also trims on start.
- Trim thresholds: ~5MB per log file; only oversized logs are trimmed.
- `AGENT_HANDOFF.txt` is the evergreen entrypoint only. Do not use it as a
  rolling execution log; current state should come from the generated handoff
  and standing-priority artifacts.
- Validate the checked-in handoff entrypoint with
  `node tools/npm/run-script.mjs handoff:entrypoint:check`. The helper writes
  `tests/results/_agent/handoff/entrypoint-status.json`, which acts as a
  machine-readable index of the canonical handoff commands and artifact paths,
  and fails when the file drifts back into historical-log mode.
- Read that same machine-readable index back through
  `node tools/npm/run-script.mjs priority:handoff`, which now prints the
  entrypoint index alongside the standing-priority snapshot and other handoff
  summaries.
- The overall future-agent handoff contract is summarized in
  [`docs/knowledgebase/Agent-Handoff-Surfaces.md`](./knowledgebase/Agent-Handoff-Surfaces.md).
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
- [`docs/RELEASE_OPERATIONS_RUNBOOK.md`](./RELEASE_OPERATIONS_RUNBOOK.md)
- [`docs/TESTING_PATTERNS.md`](./TESTING_PATTERNS.md)
- [`docs/SCHEMA_HELPER.md`](./SCHEMA_HELPER.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)

### Fork pull request automation

- Fork PRs targeting `develop` automatically run the **VI Compare (Fork PR)** workflow. The job checks out the head
  commit using the shared `fetch-pr-head` helper, stages the affected VIs, runs LVCompare on the self-hosted runner, and
  uploads artifacts identical to the `/vi-stage` workflow.
- `/vi-stage` and `/vi-history` commands remain available for both upstream and fork contributions. They now re-use the
  fetch helper so they can operate on fork heads safely.
- PR approval is no longer automated; merge queue admission relies on required checks and repository branch policy
  (currently `0` required reviewers on queue-managed branches).
- Deployment acknowledgement for protected promotion flows now uses GitHub Actions environment reviewers
  (`production`, `monthly-stability-release`) so approval notifications can be handled through GitHub's built-in
  deployment review UI (web/mobile).
- Agent reviewer routing/policy is owner-agnostic: set repository variable `REQUIRED_AGENT_REVIEWER` to pin a specific
  login; when unset it defaults to `github.repository_owner`.
- Manual `/vi-stage` and `/vi-history` workflows accept an optional `fetch_depth` input (default `20`). Increase it when
  you need additional commit history before running compares.
- Use `tools/Test-ForkSimulation.ps1` when validating fork automation. Run it in three passes: `-DryRun` prints the
  plan, the default run pushes a scratch branch, opens a draft PR, and waits for the fork compare workflow, and adding
  `-KeepBranch` preserves the branch/PR after the staging and history dispatches complete for manual inspection.
- When testing fork scenarios locally, use the composite `.github/actions/fetch-pr-head` action to simulate
  `pull/<id>/head` checkouts before invoking the staging or history helpers.
