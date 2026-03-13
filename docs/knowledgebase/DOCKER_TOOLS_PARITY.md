<!-- markdownlint-disable-next-line MD041 -->
# Docker Tools Parity Checklist

This note captures the current state of the Docker/Desktop validation helpers and how to confirm they match the Windows
tooling. It now covers both the non-LV parity path and the NI Linux review-suite evidence path.

The intended operating model is local-first: use Docker Desktop to clear deterministic markdown, workflow-drift,
NI Linux smoke, and VI history artifact defects before paying for another GitHub Actions review cycle.

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

## Review-loop policy

- First-discovery on GitHub Actions is acceptable. Repeat discovery of the same
  deterministic defect class is not.
- After the first hosted failure or review comment, prefer the local
  Docker/Desktop loop until:
  - markdownlint is clean
  - workflow-drift checks are clean
  - requirements traceability / verification is updated locally
  - NI Linux smoke is green
  - VI history review artifacts are coherent and reviewable
- Treat hosted runs as confirmation and publication surfaces once the local loop
  is already green.
- A local receipt is reusable authority only when it is:
  - green,
  - current for the exact `git.headSha`, and
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
