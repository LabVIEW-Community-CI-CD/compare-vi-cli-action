# Repository Guidelines

## Project Structure & Module Organization

- `scripts/` orchestration and helpers (compare, drift, runbook, dispatcher glue).
- `tools/` developer utilities (manifest validate/update, link checks, schema-lite).
- `tests/` Pester suites (`*.Tests.ps1`) tagged `Unit`/`Integration`.
- `module/` reusable PowerShell modules (e.g., compare loop).
- `docs/` guides and JSON schemas. Fixtures: `VI1.vi`, `VI2.vi` + `fixtures.manifest.json`.
- CI: `.github/workflows/*` and local composites under `.github/actions/*`.

## Build, Test, and Development Commands

- Unit tests: `./Invoke-PesterTests.ps1`
- Include integration: `./Invoke-PesterTests.ps1 -IncludeIntegration true`
- Filter by file pattern(s): `./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI*Tests.ps1'`
- Quick smoke (workspace temp): `./tools/Quick-DispatcherSmoke.ps1 -PreferWorkspace`
- Validate fixtures: `pwsh -NonInteractive -File tools/Validate-Fixtures.ps1 -Json`
- Orchestrated CI: preflight → pester (per-category, serial) → drift → publish.

## Coding Style & Naming Conventions

- PowerShell 7+, Pester 5+. Indent 2 spaces; UTF‑8.
- Functions PascalCase (approved verbs); locals camelCase; clear names.
- Keep code non-interactive in CI: use `pwsh -NonInteractive` for nested calls.
- Avoid writing outside `tests/results/`; prefer per-category subfolders in CI.

## Testing Guidelines

- Single Pester workflow (self-hosted Windows): `.github/workflows/pester-selfhosted.yml`.
- Categories in CI: dispatcher, fixtures, schema, comparevi, loop, runbook, orchestrator.
- Each category emits `tests/results/<category>/session-index.json` and artifacts.
- Timeouts are per-category and configurable via repo Variables (seconds):
  `PESTER_TIMEOUT_DISPATCHER`, `PESTER_TIMEOUT_FIXTURES`, `PESTER_TIMEOUT_SCHEMA`,
  `PESTER_TIMEOUT_COMPAREVI`, `PESTER_TIMEOUT_LOOP`, `PESTER_TIMEOUT_RUNBOOK`,
  `PESTER_TIMEOUT_ORCHESTRATOR`. Defaults to 150 if unset.
  Example: set `PESTER_TIMEOUT_FIXTURES=180` in Settings → Variables to extend fixtures.
  Locally, override with `-TimeoutSeconds`:
  `./Invoke-PesterTests.ps1 -IncludePatterns 'Fixtures*Tests.ps1' -TimeoutSeconds 180`.
  Session index is always written.
- LVCompare canonical path: `C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe`.
- Integration needs `LV_BASE_VI` and `LV_HEAD_VI`. Do not orchestrate `LabVIEW.exe`.

### Pre-Init Gate (Docs-only fast path)

- A pre-init gate detects docs-only changes (e.g., `docs/**`, `**/*.md`) and skips heavy Windows jobs.
- Exceptions (still run Windows where needed): `docs/schemas/**`.
- Workflow: first job `pre-init` computes `docs_only` and gates `preflight`/`pester` via `needs`/`if`.

### Hygiene, Branch Rules & Determinism

- Repo hygiene checker: `tools/Check-RepoHygiene.ps1` runs in Validate. It warns on branches; fails on `main` and `release/*`.
- Keep root minimal; move samples to `docs/samples/` and planning notes to `docs/releases/`.
- See docs/BRANCH_RULES.md for required checks and protections. Normalize booleans via `./.github/actions/bool-normalize` instead of ad-hoc parsing.
- Pre-init gate exposes `docs_only`, `fork`, and `reason` outputs for deterministic branching.

## Commit & Pull Request Guidelines

- Commits: imperative and scoped (e.g., `validator: enforce bytes`).
- PRs: include summary, risks, validation steps, linked issues; keep markdownlint and actionlint green.
- Never start tests with `LabVIEW.exe` running; preflight/guard enforces this.

### PR Labels (Bootstrap First)

- Decide labels before authoring changes. Typical labels: `ci`, `documentation`, `enhancement` (see `.github/labels.yml`).
- Ensure labels exist up front:
  - Preferred: edit `.github/labels.yml`, then run the "Sync Labels" workflow (or push to `develop`/`main` to auto‑sync).
  - Ad‑hoc (fallback): `gh label create <name> -c <hex> -d <desc>` (requires permissions).
- Apply labels as soon as the PR is opened: `gh pr edit <num> --add-label <label1> --add-label <label2>`.
- For forks without label perms: emit a summary note listing intended labels so maintainers can apply them.
- Future agents: announce intended labels in the plan, verify presence (via `gh label list`), create/sync if missing, then open the PR with labels attached.

### Labels‑Aware Agent Protocol

- Map labels to workflows and behaviors (leverage them to accomplish the deliverable):
  - `smoke`: Triggers the Smoke workflow on PRs (label‑driven run in `.github/workflows/smoke.yml`). Use to validate local action wiring quickly.
  - `test-integration`: Triggers self‑hosted Pester integration on PRs (see `.github/workflows/pester-integration-on-label.yml`). Use when the deliverable must be verified with real LVCompare.
  - `ci`: Marks CI/hardening changes; helps reviewers and automation triage.
  - `documentation`: Marks docs‑only changes; pre‑init gate will still enforce schemas under `docs/schemas/**`.
  - `enhancement`: Feature‑level changes.
- Before implementation, pick the label set that expresses: scope (docs/feature/ci) and required execution (smoke/integration). Ensure labels exist (sync or `gh label create`).
- When opening the PR, attach the chosen labels immediately. This will auto‑wire the correct workflows (e.g., `smoke`, `test-integration`).
- If labels cannot be set (forks):
  - Add a short "Intended labels" block to the PR body; the pre‑init gate will produce guidance for maintainers.
  - Optionally include a comment like: `/run pester-selfhosted` if an on‑demand run is required.
- Keep labels updated during iteration (e.g., add `ci` when switching to workflow changes).

## Security & Configuration Tips

- LVCompare‑only interface; no `LabVIEW.exe` launches from tools.
- Manifest enforces exact `bytes` and `sha256`; run validator before pushing.
- Optional leak/cleanup flags: `DETECT_LEAKS=1`, `CLEAN_AFTER=1`, `CLEAN_LVCOMPARE=1`.

## Agent Notes

- Prefer `Invoke-PesterTests.ps1` locally and in CI. Use `-IncludePatterns` to target files.
- For docs hygiene, run `tools/Check-DocsLinks.ps1` and keep markdownlint clean before PRs.
- Workflows overview: see `docs/WORKFLOWS_OVERVIEW.md` for a concise catalog of all workflows, triggers, and gates (useful to spot drift and prune duplicates).
- Pipeline depth map: see `docs/PIPELINE_GRAPH.md` for a graphical stack of gates and jobs.


### Monitor CI Runs

- Preferred (gh CLI): `gh run list -b <branch> -L 10` | `gh run view <run-id> --web`
- Scripted: `./tools/List-BranchRuns.ps1 -Branch <branch> -Limit 10`
- Filter: `./tools/List-BranchRuns.ps1 -Name 'Pester*' -Status in_progress`
- Open newest: `./tools/List-BranchRuns.ps1 -Name 'Pester (self-hosted)' -Open`

Access policy: verify login with `gh auth status -h github.com`. For scripts, tokens fall back to `GH_ADMIN_TOKEN` or `GITHUB_TOKEN` when needed.



### Autonomous PR ↔ Issue (one command)

- Use gh CLI powered end-to-end flow:
  - `./tools/Run-AutonomousPRFlow.ps1 -Base develop -Head <branch> -Title '<title>' -PrBodyPath tmp-agg/pr-body.md -IssueTitle 'Track: <summary>' -IssueBodyPath tmp-agg/issue-body.md -Open`
- Requires: `gh auth status -h github.com` is logged in.
- Behavior: creates/updates the PR, opens a tracking issue, appends `Closes #N`, prints links, and lists recent runs.

### Proactive Tracking & Suggestions

- Build context at session start (no prompts):
  - `./tools/Monitor-IssuesPRs.ps1 -Limit 50 -StaleDays 14 -OutputPath tmp-agg/monitor.md`
  - Prints open PRs/issues and a Suggestions section (stale, missing labels, missing `Closes #N`).
  - Use `-Watch` to re-run every N seconds and keep a rolling view.

### Issue / PR Body Linter

- Lint remote PR/Issue bodies (gh-first):
  - `./tools/Lint-IssueAndPRBodies.ps1 -PR 61`
  - `./tools/Lint-IssueAndPRBodies.ps1 -Issue 63`
- Lint local body draft:
  - `./tools/Lint-IssueAndPRBodies.ps1 -File tmp-agg/pr-body.md -Kind pr`
- Rules (default):
  - PR: headings for Summary, Acceptance, Validation, Risks, Links; presence of `Closes #N`; adequate length; a checklist.
  - Issue: headings for Scope, Acceptance, References; adequate length; a checklist.
  - Exit 0 on OK; 3 on errors; `-WarnOnly` to suppress failure.

## Policies & Guardrails (Strict)

- Single Windows variant: only `[self-hosted, Windows, X64]`. Do not add `windows-20xx` matrices.
- Non-interactive PowerShell: always use `pwsh -NonInteractive` for nested calls; avoid `Start-Process pwsh`. Prefer in‑process invocation.
- LVCompare‑only: never launch `LabVIEW.exe`. Preflight enforces idle LabVIEW; set `LV_SUPPRESS_UI=1` to prevent UI popups.
- No dot‑sourcing: prefer `Import-Module` for local shims/modules. Validate via `tools/Lint-DotSourcing.ps1`.
- Session index required: every category must emit `tests/results/<category>/session-index.json` (use `tools/Ensure-SessionIndex.ps1`).
- Vendor artifacts: do not commit `bin/**`. Link checker ignores it; keep vendor docs out of PRs.

### Toggles & Variables

- Protection toggles (default ON): `ENFORCE_PROTECTION_ON_DEVELOP`, `ENFORCE_PROTECTION_ON_TOPIC` (set to `0` to disable).
- Pester timeouts (seconds): `PESTER_TIMEOUT_DISPATCHER|FIXTURES|SCHEMA|COMPAREVI|LOOP|RUNBOOK|ORCHESTRATOR`.
- Guard/diagnostics: `UNBLOCK_GUARD=1`, `WATCH_CONSOLE=1`.
- Cleanup/leaks: `DETECT_LEAKS=1`, `CLEAN_AFTER=1`, `CLEAN_LVCOMPARE=1`.
- Reporter settling: `REPORT_DELAY_MS` (use sparingly; prefer event‑based readiness).

### Required Checks (reference)

- Pester (self-hosted) / preflight
- Pester (self-hosted) / pester (dispatcher|fixtures|schema|comparevi|loop|runbook|orchestrator)
- Fixture Drift Validation / Fixture Drift (Windows)
- VI Binary Handling Gate / vi-binary-check
- Validate / lint
- markdownlint / lint








### Runner Invoker (Single Execution Path)

- What: A runner-side named-pipe server that executes CompareVI, RenderReport, StepSummary, and FailureInventory.
- Why: One choke point → deterministic behavior, no UI popups, centralized logging.
- How:
  - Ensure invoker: `uses: ./.github/actions/ensure-invoker` (self-hosted jobs)
  - One-shot client: `./tools/RunnerInvoker/Send-RunnerCommand.ps1 -Verb StepSummary -Args @{ text='...' }`
  - Runner-wide (optional): `./tools/RunnerInvoker/Install-RunnerInvokerTask.ps1` (Scheduled Task)
- Flags: `INVOKER_REQUIRED=1` (enforce), `INVOKER_TELEMETRY=1`, `INVOKER_LOG_LEVEL=warn|info|debug`.
- Health check: `gh run view` + step summary blocks; or `Send-RunnerCommand.ps1 -Verb Ping`.
