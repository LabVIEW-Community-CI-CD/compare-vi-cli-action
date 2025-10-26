<!-- markdownlint-disable-next-line MD041 -->
# Developer Guide

Quick reference for building, testing, and releasing the LVCompare composite action.

## Testing

- **Unit tests** (no LabVIEW required)
  - `./Invoke-PesterTests.ps1`
  - `pwsh -File tools/Run-Pester.ps1`
- **Integration tests** (LabVIEW + LVCompare installed)
  - Set `LV_BASE_VI`, `LV_HEAD_VI`
  - `./Invoke-PesterTests.ps1 -IntegrationMode include`
- **Helpers**
  - `tools/Dev-Dashboard.ps1` → telemetry snapshot
  - `tools/Watch-Pester.ps1` → file watcher / retry loop
  - `tools/Detect-RogueLV.ps1 -FailOnRogue` → leak check

Artifacts land in `tests/results/` (JSON summaries, XML, loop logs).

See `docs/plans/VALIDATION_MATRIX.md` for a standing-priority view of the major validation entry points, including
docker workflows and the integration gate. VS Code users can launch the same commands via the bundled tasks in
`.vscode/tasks.json` (Command Palette -> "Run Task"); leak-handling switches are already wired in so LabVIEW closes
after each sweep.

- macOS/Linux users must install PowerShell 7 and expose `pwsh` on `PATH` so the tasks can resolve the shell.
- When LabVIEW is unavailable, run `pwsh -File Invoke-PesterTests.ps1 -IntegrationMode exclude` manually and omit the
  leak-cleanup flags until the standing-priority tasks land on those platforms.

For container parity prerequisites and cleanup tips, refer to `docs/knowledgebase/DOCKER_TOOLS_PARITY.md`.

## Pull request hygiene

```powershell
pwsh -File tools/Check-PRMergeable.ps1 -Number <pr> -FailOnConflict
```

Use this after opening a PR to poll GitHub's mergeable state (exits non-zero when conflicts are detected).

## Building & linting

```powershell
node tools/npm/cli.mjs ci
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
- When rehearsing feature branch work, use `npm run feature:branch:dry -- my-feature` and
  `npm run feature:finalize:dry -- my-feature` to simulate branch creation and finalization without touching remotes.
- Delete branches automatically after merging (GitHub setting) so the standing-priority flow starts clean each time.

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
  via `npm run history:run -- -ViPath Fixtures/Loop.vi -StartRef HEAD -MaxPairs 3`.
- `scripts/Dispatch-VIHistoryWorkflow.ps1` - wraps `gh workflow run` for
  `vi-compare-refs.yml`, echoes the latest run id/link, and records dispatch
  metadata under `tests/results/_agent/handoff/vi-history-run.json` for
  follow-up. Invoke with
  `npm run history:dispatch -- -ViPath Fixtures/Loop.vi -CompareRef develop -NotifyIssue 317`.
- VS Code tasks **VI History: Run local suite** and **VI History: Dispatch
  workflow** prompt for VI path/refs and route through the same scripts so
  editors can trigger the flow without remembering the parameters.

## Watch mode tips

```powershell
$env:WATCH_RESULTS_DIR = 'tests/results/_watch'
pwsh -File tools/Watch-Pester.ps1 -RunAllOnStart -ChangedOnly
```

Artifacts: `watch-last.json`, `watch-log.ndjson`. Dev Dashboard surfaces these along with
queue telemetry and stakeholder contacts.

## Handoff telemetry & auto-trim

```powershell
pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim
```

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
pwsh -File scripts/CompareVI.ps1 -Base VI1.vi -Head VI2.vi -LvCompareArgs "-nobdcosm" -PreviewArgs
```

## References

- [`docs/INTEGRATION_RUNBOOK.md`](./INTEGRATION_RUNBOOK.md)
- [`docs/TESTING_PATTERNS.md`](./TESTING_PATTERNS.md)
- [`docs/SCHEMA_HELPER.md`](./SCHEMA_HELPER.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)

