<!-- markdownlint-disable-next-line MD041 -->
# Agent Handbook

This document summarizes the expectations for automation agents working in the `compare-vi-cli-action` repository. The
style mirrors the reflowed `README.md` so `markdownlint` remains quiet (120-column guideline, explicit headings, blank-
line buffers).

## Primary directive

- The standing priority is whichever issue carries the active standing-priority
  label for the current repository context:
  - canonical/upstream: `standing-priority`
  - fork repos: `fork-standing-priority` (with fallback to
    `standing-priority` for compatibility)
  Use the sanitized wrappers (`node tools/npm/cli.mjs <command>` /
  `node tools/npm/run-script.mjs <script>`) instead of raw `npm` invocations
  (the container exports `npm_config_http_proxy`, which triggers warnings in
  recent npm builds). Run `pwsh -NoLogo -NoProfile -File
  tools/priority/bootstrap.ps1` at session start so
  `.agent_priority_cache.json` and `tests/results/_agent/issue/` reflect the
  latest snapshot, hook preflight succeeds, and the working tree is anchored to
  `develop`; treat that issue as the top objective for edits, CI runs, and PRs.
- The human operator is signed in with an admin GitHub token; assume privileged operations (labels, reruns, merges) are
  allowed when safe.
- Default behaviour:
  - Operate inside this repository unless the human asks otherwise.
  - Keep workflows deterministic and green.
  - Reference the current standing-priority issue (e.g., `#<standing-number>`) in commit and PR descriptions.
  - Scope boundary: this repository is for compare-vi CLI action workflows only.
    LabVIEW icon editor development moved to
    `svelderrainruiz/labview-icon-editor` and must not be treated as
    standing-priority scope here.
- First actions in a session:
  1. `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1` to run hook preflight, refresh the standing-priority
     snapshot/router artifacts, and auto-anchor the workspace to `develop`. When PowerShell + Node aren't available on
     the host plane, use the Docker fallback:
     - `pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -ToolsImageTag comparevi-tools:local
       -UseToolsImage -PrioritySync -SkipActionlint -SkipMarkdown -SkipDocs -SkipWorkflow -SkipDotnetCliBuild`
     - `node tools/npm/run-script.mjs priority:sync:docker`
     Ensure a GitHub token is supplied via `GH_TOKEN`/`GITHUB_TOKEN` or `GH_TOKEN_FILE`
     (default `C:\github_token.txt`). The helper injects the token into the container
     without writing it to logs. Set `COMPAREVI_TOOLS_IMAGE=ghcr.io/labview-community-ci-cd/comparevi-tools:latest`
     to use the published tools image instead of building locally. After the Docker fallback completes, manually verify
     the working tree is on `develop` before creating a feature branch.
  2. Review `.agent_priority_cache.json` / `tests/results/_agent/issue/` for tasks, acceptance, and
     linked PRs on the standing issue.
  3. Run `node tools/priority/report-origin-upstream-parity.mjs --base-ref upstream/develop --head-ref origin/develop`
     and use `tipDiff.fileCount` as the primary origin/upstream alignment KPI (`0` means branch-tip content parity).
  4. Create or sync a working branch (`issue/<standing-number>-<slug>`), push minimal changes,
     dispatch CI, update the PR (reference `#<standing-number>`), monitor to green, merge when
     acceptance is met.

## Streaming guardrails

- Heavy log archives and binary fixtures previously pushed this workspace over Codex streaming limits. We trimmed the
  checked-in payloads (`logs/2025-10-09`, `job-*.log`, `tmp-win-drift.log`, `tmp_predefined.html`, drift artifact zips)
  so future agents start below the ceiling.
- Keep bulky diagnostics out of source. When capturing long logs, prefer short repro snippets or attach artifacts to
  issues instead of committing them.
- `.openai-ignore` enumerates directories/files Codex should skip to stay under streaming limits. Update that list if
  new large assets appear (and remove the assets from git when possible).

## Repository layout

- `scripts/` – PowerShell modules and shims (prefer `Import-Module`, avoid dot-sourcing).
- `tools/` – local/CI utilities; telemetry collectors; workflow helpers.
- `tests/` – Pester v5 suites (`Unit`, `Integration`); use `$TestDrive` for temp files.
- `.github/workflows/` – self-hosted and hosted pipelines; see README for highlights.
- `Invoke-PesterTests.ps1` – entry point for local runs and CI orchestration.

## Build / test / develop

- Unit tests: `./Invoke-PesterTests.ps1`
- Integration: `./Invoke-PesterTests.ps1 -IntegrationMode include`
- Custom paths: `./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results`
- Pattern filter: `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI.*'`
- Staging smoke:
  - `pwsh -File tools/Test-PRVIStagingSmoke.ps1 -DryRun` (plan only)
  - `node tools/npm/run-script.mjs smoke:vi-stage` (full run; uses fixtures/vi-attr for a baked-in VI
    attribute diff)
  Both flows post artifact links and the updated PR summary comment.
- Containerized non-LV checks: `pwsh -File tools/Run-NonLVChecksInDocker.ps1`
- Compare harnesses default to headless CLI runs (`LVCI_COMPARE_POLICY=cli-only`). Override with `lv-only` only when you
  explicitly need the LVCompare UI; otherwise leave it unset to avoid prompts and stuck LabVIEW instances.
  - Note (scope): `LVCI_COMPARE_MODE`/`LVCI_COMPARE_POLICY` apply to harness/workflow helpers only. The composite
    action always invokes LVCompare directly and does not honor these toggles.
- Icon editor note:
  - Icon editor tooling in this repository is historical compatibility material
    only. Active icon editor development and operational runbooks now live in
    `svelderrainruiz/labview-icon-editor`.

## Coding style

- PowerShell 7+, Pester v5+. Match surrounding indentation (2–4 spaces).
- Avoid nested `pwsh`; use in-process execution or `ProcessStartInfo` with `UseShellExecute=false`.
- For local scripts and non-harness flows, call **LVCompare** (canonical path under Program Files). Do not launch
  `LabVIEW.exe` directly. The automation defaults to the LabVIEW CLI path for headless capture; avoid starting the
  LabVIEW UI.
- CI is non-interactive; avoid prompts and pop-ups.

## Testing guidelines

- Shadow helpers inline inside `It {}` blocks, then remove.
- Keep integration tests isolated; unit tests should be fast.
- Standard results live under `tests/results/` (summary JSON, XML, session index).

## Wire probes (Long-Wire v2)

- Probes are injected by `tools/workflows/update_workflows.py`.
- Toggle with repo variable `WIRE_PROBES=0` (default enabled).
- Phase markers (`_wire/phase.json`):
  - `J1` / `J2` – before/after checkout.
  - `T1` – before Pester categories.
  - `C1` / `C2` – fixture drift job.
  - `I1` / `I2` – invoker start/stop.
  - `S1` – session index post.
  - `G0` / `G1` – runner unblock guard.
  - `P1` – final summary append.
- Inspect `_wire` directories or step summaries for timing markers.

## Commits & PRs

- Keep commits focused; include `#<standing-number>` in subjects.
- PRs should describe rationale, list affected workflows, and link to artifacts.
- Ensure CI is green (lint + Pester). Verify no lingering processes on self-hosted runners.
- For `gh issue create` / `gh issue edit` with multiline Markdown bodies in mixed
  WSL/Windows shells, prefer `--body-file <path>` (or `-F`) over inline
  `--body "..."` to avoid backtick command substitution and quoting drift.
  Example:

  ```bash
  gh issue create --title "<title>" --body-file issue-body.md
  gh issue edit <number> --body-file issue-body.md
  ```

## Local gates (pre-push)

- Run `tools/PrePush-Checks.ps1` before pushing:
  - Installs `actionlint` (`vars.ACTIONLINT_VERSION`, default 1.7.7) if missing.
  - Runs `actionlint` across `.github/workflows`.
  - Runs safe PR watch task contract validation (`safe-watch:contract`).
  - Optionally round-trips YAML with `ruamel.yaml` (if Python available).
  - Validate safe PR watch task contracts manually before task/workspace changes when iterating locally:
    - `node tools/npm/run-script.mjs safe-watch:contract`
  - For mixed WSL/Windows shells, prefer HTTPS fetch + SSH push on `origin` to avoid
    `git ls-remote` auth drift across terminals:
    - `git remote set-url origin https://github.com/<owner>/<repo>.git`
    - `git remote set-url --push origin git@github.com:<owner>/<repo>.git`
- For VI history/container work, run Docker fast-loop before push:
  - Single-lane strict (recommended first, no runtime auto-repair/engine switching):
    - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope linux -StepTimeoutSeconds 600`
    - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope windows -StepTimeoutSeconds 600`
  - Full dual-lane validation:
    - `pwsh -NoLogo -NoProfile -File tools/Test-DockerDesktopFastLoop.ps1 -LaneScope both -StepTimeoutSeconds 600`
  - `-ManageDockerEngine` is only allowed with `-LaneScope both`.
- Markdown lint changed-file contract:
  - `tools/Lint-Markdown.ps1` and `tools/lint-markdown.mjs` suppress temporary
    draft files (`.tmp-*.md`, `pr-*-body.md`) during changed-file runs.
  - Tracked markdown is still linted; temp-file suppression is only for
    untracked local drafts.
- Optional hook workflow:
  1. `git config core.hooksPath tools/hooks`
  2. Copy `tools/hooks/pre-push.sample` to `tools/hooks/pre-push`
  3. The hook runs the script and blocks on failure.

## Optional hooks (developer opt-in)

- `tools/hooks/pre-commit.sample`
  - Runs PSScriptAnalyzer (if installed) on staged PS files.
  - Warns on inline `-f` and dot-sourcing.
  - Blocks on analyzer errors.
- `tools/hooks/commit-msg.sample`
  - Enforces subject ≤100 characters and an issue reference (e.g., `(#123)`) unless `WIP`.

## Required checks (develop)

- Enforce the required statuses listed in `tools/policy/branch-required-checks.json` (contract source of truth). At
  present these are: `lint`, `fixtures`, `session-index`, `issue-snapshot`, `semver`,
  `hook-parity (windows-latest)`, `hook-parity (ubuntu-latest)`, and `vi-history-scenarios-linux`.
  Optionally apply the same requirement to `main` per repository policy.
- One-time GitHub CLI snippet (admin only):

  ```bash
  gh api repos/$REPO/branches/develop/protection \
    -X PUT \
    -f required_status_checks.strict=true \
    -f required_status_checks.contexts[]='lint' \
    -f required_status_checks.contexts[]='fixtures' \
    -f required_status_checks.contexts[]='session-index' \
    -f required_status_checks.contexts[]='issue-snapshot' \
    -f required_status_checks.contexts[]='semver' \
    -f required_status_checks.contexts[]='hook-parity (windows-latest)' \
    -f required_status_checks.contexts[]='hook-parity (ubuntu-latest)' \
    -f required_status_checks.contexts[]='vi-history-scenarios-linux' \
    -H "Accept: application/vnd.github+json"
  ```

## Branch protection contract (#118)

- Canonical required-status mapping lives in `tools/policy/branch-required-checks.json` (hash = contract digest).
- `tools/Update-SessionIndexBranchProtection.ps1` injects the verification block into `session-index.json` and emits a
  step-summary entry.
- When validating Branch Protection locally:

  ```powershell
  pwsh -File tools/Quick-DispatcherSmoke.ps1 -PreferWorkspace -ResultsPath .tmp/sessionindex
  pwsh -File tools/Update-SessionIndexBranchProtection.ps1 -ResultsDir .tmp/sessionindex `
    -PolicyPath tools/policy/branch-required-checks.json `
    -Branch (git branch --show-current)
  ```

Staging smoke runs use the dedicated helper (`Test-PRVIStagingSmoke.ps1`) so staged VI bundles and LVCompare outputs
are exercised end-to-end.

- Confirm `session-index.json` contains `branchProtection.result.status = "ok"`; mismatches should be logged in
  `branchProtection.notes`.
- If CI reports `warn`/`fail`, inspect the Step Summary and the session index artifact from that job. Update branch
  protection or the mapping file as needed to realign.

## Workflow maintenance

Use `tools/workflows/update_workflows.py` for mechanical updates (comment-preserving).

- Suitable tasks:
  - Add hosted Windows notes.
  - Inject `session-index-post` steps.
  - Normalize Runner Unblock Guard placement.
  - Adjust pre-init `force_run` gates.
- Avoid for logical edits (needs graphs, job logic). Modify manually, then run `actionlint`.
- Usage:

  ```bash
  python tools/workflows/update_workflows.py --check .github/workflows/ci-orchestrated.yml
  python tools/workflows/update_workflows.py --write .github/workflows/ci-orchestrated.yml
  ./bin/actionlint -color
  ```

## Agent hand-off & telemetry

- Keyword **handoff**:
  1. Read `AGENT_HANDOFF.txt`, confirm plan.
  2. Set safe env toggles:
     - `LV_SUPPRESS_UI=1`
     - `LV_NO_ACTIVATE=1`
     - `LV_CURSOR_RESTORE=1`
     - `LV_IDLE_WAIT_SECONDS=2`
     - `LV_IDLE_MAX_WAIT_SECONDS=5`
  3. Rogue scan: `pwsh -File tools/Detect-RogueLV.ps1 -ResultsDir tests/results -LookBackSeconds 900
     -AppendToStepSummary`
  4. Sweep LVCompare (only) if rogues found and human approves.
  5. Honour pause etiquette (“brief delay (~90 seconds)”) and log waits.
  6. Execute “First Actions for the Next Agent” from `AGENT_HANDOFF.txt`.
- Convenience helpers:
  - `pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles`
  - `pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim`
    - Prints a concise watcher summary (state, heartbeatFresh, needsTrim) and
      emits a compact JSON block to `tests/results/_agent/handoff/watcher-telemetry.json`.
    - When `-AutoTrim` (or `HANDOFF_AUTOTRIM=1`) is set, trims oversized watcher logs if eligible
      and appends notes to the GitHub Step Summary when available.
    - Each invocation also drops a session capsule under `tests/results/_agent/sessions/`
      (schema `agent-handoff/session@v1`) capturing branch/head/status snapshots for determinism.
- Capture quick regression coverage with `node tools/npm/run-script.mjs priority:handoff-tests`; the script runs
  `priority:test`, `hooks:test`, and `semver:check`, then writes `tests/results/_agent/handoff/test-summary.json` so
  subsequent agents (or CI summaries) can replay the outcomes.

## Fast path for standing-priority flows (historical: #127)

- PR comment dispatch: `/run orchestrated single include_integration=true sample_id=<id>`
- CLI dispatch: `pwsh -File tools/Dispatch-WithSample.ps1 ci-orchestrated.yml -Ref develop -IncludeIntegration true`
- Merge policy: once required checks pass and acceptance criteria satisfied, merge (admin token available).

## Single-strategy fallback

- `probe` job detects interactivity.
- `windows-single` runs only when `probe.ok == true`.
- If `strategy=single` but `probe.ok == false`, fall back to `pester-category`.
- Hosted preflight remains notice-only for LVCompare presence.

## Re-run with same inputs

- Summaries include a copy/pastable `gh workflow run` command.
- Use `node tools/npm/run-script.mjs priority:validate -- --ref <branch>` to dispatch
  Validate from upstream; the helper blocks fork refs unless you pass `--allow-fork`
  (or `VALIDATE_DISPATCH_ALLOW_FORK=1`).
- Comment snippets documented in `.github/PR_COMMENT_SNIPPETS.md`.

## Watching orchestrated runs

- Prefer the REST watcher when monitoring workflows: `node tools/npm/run-script.mjs ci:watch:rest -- --run-id <id>`
  streams job status and exits non-zero if the run fails. Passing `--branch <name>` auto-selects the latest run. The VS
  Code task “CI Watch (REST)” prompts for a run id.
- The watcher now aborts with `conclusion: watcher-error` after repeated 404s or other API failures (90s / 120s grace by
  default), still writing `watcher-rest.json` so session-index telemetry isn’t lost. Explicit rate-limit responses
  short-circuit with instructions to supply `GH_TOKEN`/`GITHUB_TOKEN` (or wait for the reset) instead of waiting out the
  error window.
- Use the Docker watcher (`tools/Watch-InDocker.ps1`) when you need dispatcher logs or artifact download mirrors. Both
  watchers honor `GH_TOKEN`/`GITHUB_TOKEN` and fall back to `C:\github_token.txt` on Windows.
- Keep watcher summaries in `tests/results/_agent/` up to date so downstream agents inherit telemetry context.
- `tools/Update-SessionIndexWatcher.ps1` merges `watcher-rest.json` into `session-index.json`, exposing the REST watcher
  status under the `watchers.rest` node. Run it after the watcher step if you update the workflow or run the watcher
  manually.
- For PR status polling in VS Code terminals, prefer snapshot mode instead of `gh pr checks --watch`:
  - VS Code task: `CI: Watch PR checks (safe snapshot)`
  - Workspace tasks:
    - `Command Center: watch PR checks (safe, fork plane)`
    - `Fork Plane: watch PR checks (safe)`
    - `Upstream Plane: watch PR checks (safe)`
  - CLI equivalent: `node tools/npm/run-script.mjs ci:watch:safe -- --PullRequest <pr-number> -IntervalSeconds 20`
  - The helper emits delta/heartbeat summaries using repeated `gh pr checks --json` snapshots and avoids high-volume
    repaint loops that can destabilize integrated terminals.
  - Smoke-check the watcher behavior (expected: one summary line plus either delta entries or a no-change heartbeat):

    ```bash
    node tools/npm/run-script.mjs ci:watch:safe -- --PullRequest <pr-number> \
      -IntervalSeconds 20 -HeartbeatPolls 1 -MaxPolls 2
    ```

  - If `safe-watch:contract` fails, restore expected task labels/inputs and argument wiring in:
    - `.vscode/tasks.json`
    - `compare-vi-cli-action.code-workspace`
    - `compare-vi-cli-action.command-center.code-workspace`
    - `compare-vi-cli-action.fork-plane.code-workspace`
    - `compare-vi-cli-action.upstream-plane.code-workspace`

## LVCompare observability

- Notices are written to `tests/results/_lvcompare_notice/notice-*.json` (phases: pre-launch, post-start, completed,
  post-complete).
- `tools/Detect-RogueLV.ps1` checks for untracked LVCompare/LabVIEW processes.
- Environment safeguards: `LV_NO_ACTIVATE=1`, `LV_CURSOR_RESTORE=1`, `LV_IDLE_WAIT_SECONDS=2`,
  `LV_IDLE_MAX_WAIT_SECONDS=5`.

## Telemetry & wait etiquette

- Use `tools/Agent-Wait.ps1` to record wait windows:

  ```powershell
  . ./tools/Agent-Wait.ps1
  Start-AgentWait -Reason 'workflow propagation' -ExpectedSeconds 90
  # ... after human responds
  End-AgentWait
  ```

- Artifacts land in `tests/results/_agent/`. Summaries update automatically in CI.

## Deterministic orchestration runbook (#683)

- Default operating mode: deterministic handoff with a single active writer.
- Role windows (SLA targets):
  - implementer: 0-45 minutes from assignment to first checkpoint.
  - reviewer: 0-30 minutes from implementer handoff to disposition (approve/request changes).
  - audit: 0-30 minutes from reviewer disposition to evidence verification and issue/PR log update.

### Machine-readable checkpoint contract

Post checkpoints in the standing issue using this JSON block (inside a fenced `json` code block):

```json
{
  "schema": "standing-checkpoint@v1",
  "issue": 683,
  "cycle": 1,
  "role": "implementer",
  "owner": "<login>",
  "windowStartUtc": "<ISO-8601>",
  "windowEndUtc": "<ISO-8601>",
  "evidence": {
    "commands": ["<cmd1>", "<cmd2>"],
    "artifacts": ["<path-or-url>"],
    "result": "pass|fail|blocked"
  },
  "nextOwner": "<login>",
  "nextRole": "reviewer|audit|implementer"
}
```

### Deterministic escalation matrix

- SLA breach (< 15m over window): post checkpoint with `result=blocked`, keep owner, continue execution.
- SLA breach (>= 15m and < 60m): transfer to next role owner and log transfer reason in checkpoint evidence.
- SLA breach (>= 60m) or policy deadlock: escalate to repository maintainers,
  add `admin-override-candidate` note in standing issue, and pause destructive
  operations until disposition.

### Single-writer protocol (overlapping file scopes)

- One writer per file scope at a time (`.github/workflows/**`, `tools/priority/**`, `docs/**`, etc.).
- Before edits, announce ownership window in checkpoint JSON (`role=implementer`).
- Reviewer/audit roles are read-only for owned scopes unless ownership is explicitly transferred in a checkpoint.
- If overlap is unavoidable, split by disjoint file scopes and record both owners in consecutive checkpoints.

## Troubleshooting quick links

- Rogue LVCompare: `tools/Detect-RogueLV.ps1 -FailOnRogue`
- Session lock: `docs/SESSION_LOCK_HANDOFF.md`
- Runbook: `docs/INTEGRATION_RUNBOOK.md`
- Fixture drift: `docs/FIXTURE_DRIFT.md`
- Loop mode: `docs/COMPARE_LOOP_MODULE.md`

## Vendor tool resolvers

Use the shared resolver module to locate vendor CLIs consistently across OSes and self-hosted runners. This avoids PATH
drift and issues like picking a non-Windows binary on Windows.

- Module: `tools/VendorTools.psm1`
- Functions:
  - `Resolve-ActionlintPath` – returns `bin/actionlint.exe` on Windows or `bin/actionlint` elsewhere.
  - `Resolve-MarkdownlintCli2Path` – returns local CLI from `node_modules/.bin` (cmd/ps1 on Windows).
  - `Get-MarkdownlintCli2Version` – reads installed or declared version (no network).
  - `Resolve-LVComparePath` – returns canonical `LVCompare.exe` under Program Files (Windows only).

Examples:

```powershell
# In tools/* scripts
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1') -Force
$alPath = Resolve-ActionlintPath
$mdCli  = Resolve-MarkdownlintCli2Path
$mdVer  = Get-MarkdownlintCli2Version
```

```powershell
# In scripts/* modules (one directory up from tools/)
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force
$lvCompare = Resolve-LVComparePath
```

Guidance:

- Prefer resolvers over hardcoded paths or PATH lookups in local scripts.
- For markdownlint, try `Resolve-MarkdownlintCli2Path`; only fall back to `npx --no-install` when necessary.
- For LVCompare, continue to enforce the canonical path; pass `-lvpath` to LVCompare and never launch `LabVIEW.exe`.
- Do not lint or link-check vendor documentation under `bin/`; scope link checks to `docs/` or ignore `bin/**`.
