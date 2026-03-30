<!-- markdownlint-disable-next-line MD041 -->
# Docker Tools Parity Checklist

This note captures the current state of the Docker/Desktop validation helpers and how to confirm they match the Windows
tooling. It now covers both the non-LV parity path and the NI Linux review-suite evidence path.

The intended operating model is local-first: use Docker Desktop to clear deterministic markdown, workflow-drift,
NI Linux smoke, and VI history artifact defects before paying for another GitHub Actions review cycle.

The lane split is intentional:

- `tools/PrePush-Checks.ps1` is the blocking rendered-review gate plus a minimal transport/bootstrap smoke and a
  non-blocking dependency-audit observation receipt under `tests/results/_agent/security/`.
- `tools/Invoke-NILinuxReviewSuite.ps1` is the broader flag-combination certification surface.

Workflow-grade replay lanes now sit alongside that review loop:

- Linux replay: `node tools/npm/run-script.mjs priority:workflow:replay:docker -- --mode session-index-v2-promotion --run-id <id> --repo <owner/repo>`
- Windows replay: `node tools/npm/run-script.mjs priority:workflow:replay:windows`

The replay receipts are deterministic and land under `tests/results/docker-tools-parity/workflow-replay/`.

## Environment prerequisites

- Docker Desktop (or Engine) must be available. On Windows, confirm with `docker version`; the client/server details
  should show `Docker Desktop` with the expected engine revision.
- Ensure `GH_TOKEN`/`GITHUB_TOKEN` are available (the helper forwards them into containers when defined).

## Quick parity run

```powershell
pwsh -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage
pwsh -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite
pwsh -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -RequirementsVerification
```

- The `dotnet-cli-build (sdk)` container publishes the CompareVI CLI into `dist/comparevi-cli/`. Expect artifacts:
  - `comparevi-cli.dll`, `CompareVi.Shared.dll`, matching `.deps.json` and `.runtimeconfig.json` files.
- `actionlint` runs inside the tools image (or `rhysd/actionlint` if `-UseToolsImage` isn't specified). Successful runs
  print `[docker] actionlint OK`.
- Optional flags (`-SkipDocs`, `-SkipWorkflow`, `-SkipMarkdown`) remain available when you want a quicker loop while
  iterating locally.
- `-NILinuxReviewSuite` drives `tools/Invoke-NILinuxReviewSuite.ps1` from the host plane against Docker Desktop/Linux
  and writes GitHub Pages-ready HTML/JSON outputs under
  `tests/results/docker-tools-parity/ni-linux-review-suite/`, including:
  - `review-suite-summary.html`
  - `flag-combination-certification.html`
  - `flag-combination-certification.json`
  - `vi-history-report/results/history-report.html`
  - `vi-history-report/results/history-summary.json`
  - `vi-history-report/results/history-suite-inspection.html`
  - `vi-history-review-loop-receipt.json`
- `-RequirementsVerification` runs `tools/Verify-RequirementsGate.ps1` inside the tools container and writes
  deterministic traceability artifacts under `tests/results/docker-tools-parity/requirements-verification/`, including:
  - `verification-summary.json`
  - `trace-matrix.json`
  - `trace-matrix.html`
- Every run now also emits the combined top-level receipt
  `tests/results/docker-tools-parity/review-loop-receipt.json`. Read that file first after compaction; it records
  per-check status, links to the current NI Linux and requirements artifacts, lists the recommended review order, and
  now stamps the local review with `git.headSha`, `git.branch`, and `git.upstreamDevelopMergeBase` so future agents can
  reject stale green receipts after the branch head changes.
- The same run also refreshes
  `tests/results/_agent/verification/docker-review-loop-summary.json`, a bounded `_agent`-facing bridge that points to
  the authoritative Docker/Desktop requirements verification artifacts. Future agents should treat this file as the
  authoritative `_agent` verification surface when resuming local review work.
- When the unattended delivery daemon consumes that receipt, it now mirrors the normalized summary into
  `tests/results/_agent/runtime/delivery-agent-state.json` and the active lane record under
  `tests/results/_agent/runtime/delivery-agent-lanes/`. Future agents should read the runtime-state `localReviewLoop`
  node first when resuming a daemon-driven lane, then open the deeper Docker/Desktop receipt paths only when needed.

## Workflow-grade replay lane

For workflow-grade replay against real GitHub Actions evidence, use the checked-in Docker replay helper:

```powershell
node tools/npm/run-script.mjs priority:workflow:replay:docker -- --mode session-index-v2-promotion --run-id 23543808174 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action
```

- The first delivered mode is `session-index-v2-promotion`.
- The helper runs the checked-in workflow helper inside the CompareVI tools image rather than inventing a separate
  replay implementation.
- Outer receipt:
  - `tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion-receipt.json`
- Inner replay artifacts:
  - `tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/`
- Image selection fails closed in this order:
  - explicit `--image`
  - `COMPAREVI_TOOLS_IMAGE`
  - local `comparevi-tools:local`
  - published `ghcr.io/labview-community-ci-cd/comparevi-tools:latest`
- Token resolution fails closed in this order:
  - `GH_TOKEN`
  - `GITHUB_TOKEN`
  - `gh auth token`

This first slice is Linux-first. For Windows Docker/Desktop parity today, continue to use the existing NI Windows proof
surfaces and host preflight path. Workflow-grade Windows replay is the next extension under the same replay-lane
objective, not a separate ad hoc lane.

## Review-loop policy

- First-discovery on GitHub Actions is acceptable. Repeat discovery of the same
  deterministic defect class is not.
- After the first hosted failure or review comment, prefer the local
  Docker/Desktop loop until:
  - markdownlint is clean
  - workflow-drift checks are clean
  - requirements traceability / verification is updated locally
  - the blocking rendered-review gate is green
  - NI Linux certification artifacts are green when you are changing compare/runtime behavior
  - VI history review artifacts are coherent and reviewable
- Treat hosted runs as confirmation and publication surfaces once the local loop
  is already green.
- A local receipt is reusable authority only when it is:
  - green,
  - current for the exact `git.headSha`, and
  - tracked-clean in both the live worktree and the receipt metadata, and
  - complete for the requested review surfaces (for example markdown, requirements,
    NI Linux suite, and any requested single-VI history target).
  A current-head receipt that skipped one of the requested surfaces must be
  treated as under-scoped and rerun locally before another hosted confirmation pass.

## Targeted single-VI history follow-up

- The parity helper now surfaces the targeted branch-history inputs directly:

```powershell
pwsh -File tools/Run-NonLVChecksInDocker.ps1 `
  -UseToolsImage `
  -SkipActionlint -SkipDocs -SkipWorkflow -SkipDotnetCliBuild `
  -SkipMarkdown `
  -NILinuxReviewSuite `
  -NILinuxReviewSuiteHistoryTargetPath 'fixtures/vi-attr/Head.vi' `
  -NILinuxReviewSuiteHistoryBranchRef 'develop' `
  -NILinuxReviewSuiteHistoryBaselineRef 'HEAD~128' `
  -NILinuxReviewSuiteHistoryMaxCommitCount 1024
```

- That targeted path must be touch-aware for deep branches such as `develop`, so
  it reviews only the commits that actually changed the selected VI instead of
  replaying all branch commits.
- The helper now emits `vi-history-review-loop-receipt.json`, a deterministic
  artifact that records the selected target/ref inputs, the effective refs, the
  bootstrap pair-selection counts, and the recommended artifact review order so
  future agents can resume after context compaction.
- The top-level `review-loop-receipt.json` now wraps that single-VI receipt
  together with markdown/docs/workflow status and requirements coverage so
  future agents only need one starting artifact before opening the deeper VI
  history evidence.

## Windows workflow-grade replay

Use the Windows replay companion when a defect depends on Docker Desktop Windows
container mode, the pinned NI Windows image, or the Windows shell boundary:

```powershell
node tools/npm/run-script.mjs priority:workflow:replay:windows
node tools/npm/run-script.mjs priority:workflow:replay:windows:vi-history
```

Hosted-parity preflight without mutating the local Docker engine:

```powershell
node tools/npm/run-script.mjs priority:workflow:replay:windows -- --execution-surface github-hosted-windows --allow-unavailable
```

Primary artifacts:

- `tests/results/docker-tools-parity/workflow-replay/windows-ni-2026q1-host-preflight-receipt.json`
- `tests/results/docker-tools-parity/workflow-replay/windows-ni-2026q1-host-preflight/windows-ni-2026q1-host-preflight.json`
- `tests/results/docker-tools-parity/workflow-replay/vi-history-scenarios-windows-receipt.json`
- `tests/results/docker-tools-parity/workflow-replay/vi-history-scenarios-windows/windows-compare-report.html`
- `tests/results/docker-tools-parity/workflow-replay/vi-history-scenarios-windows/windows-compare-artifact-summary.json`

Policy notes:

- `desktop-local` is fail-closed when Docker Desktop is still on the Linux engine.
- `github-hosted-windows` may emit `status = unavailable` when the hosted Windows
  Docker plane is not usable and `--allow-unavailable` was requested.
- The Windows replay lane is proof-only. It is not a release path.
- `priority:workflow:replay:windows:vi-history` is the local fast loop for the
  hosted `vi-history-scenarios-windows` lane. It is still a replay lane, not a
  certification substitute.

## Cleanup expectations

- After parity validation, remove `dist/comparevi-cli/`:

  ```powershell
  Remove-Item -LiteralPath dist/comparevi-cli -Recurse -Force
  ```

- Verify `git status` returns clean output (aside from intentional working-tree changes).

## Troubleshooting

- **Docker daemon missing** – `open //./pipe/dockerDesktopLinuxEngine` (Windows) means Docker Desktop isn’t running.
  Start Docker, re-run `docker version`, and retry the helper.
- **Permission issues** – ensure your user is authorized to run Docker commands; add to the `docker-users` group when
  needed.
- **Token forwarding** - if `GH_TOKEN` / `GITHUB_TOKEN` are required, set them before running the helper. Without a
  token, `priority:sync` inside the container may fail.

## Automation support

- GitHub workflow `Tools Parity (Linux)` (`.github/workflows/tools-parity.yml`) runs the helper on `ubuntu-latest`.
  Trigger it via `workflow_dispatch` to capture fresh parity logs and a `docker version` snapshot. Artifacts are uploaded
  as `docker-parity-linux` and `docker-parity-linux-review-loop` (example run:
  https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/18703466772).
- Adjust the workflow inputs to re-enable docs, workflow checkout contracts, markdown checks, or the NI Linux review
  suite when validating broader coverage.
- The workflow can also upload requirements traceability evidence as
  `docker-parity-linux-requirements-verification`.

## macOS coverage (help wanted)

- The tools image cannot run on macOS-hosted GitHub runners (Docker Desktop is not available), so parity needs to be
  captured on a physical/virtual Mac with Docker running.
- Contributions welcome: run the parity helper locally on macOS, record `docker version` + script logs, and update this
  guide (and the validation matrix) with findings.

## Status (2025-10-22)

- Parity check completed on Windows with Docker Desktop 4.47.0 (Engine 28.4.0). CLI build succeeded; cleanup confirmed.
- Full helper sweep (docs, workflow checkout contracts, markdown) now runs cleanly after lint fixes logged in develop (Oct 22).
- Documentation updated (validation matrix) to remind contributors to remove `dist/comparevi-cli/` after runs.
- Linux automation added via `Tools Parity (Linux)` workflow; macOS parity remains open for contribution.
