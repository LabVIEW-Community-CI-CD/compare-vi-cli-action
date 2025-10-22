<!-- markdownlint-disable-next-line MD041 -->
# Feature Branch Enforcement & Merge Queue

_Last updated: 2025-10-22 (standing priority #285)._

## Purpose

Serve as the canonical quick reference for how contributors branch, validate, and promote work while satisfying the
standing GitHub protection rules (including the `main` merge queue).

## Branch Expectations

| Branch pattern            | Purpose                               | Creation helper                                                 | Merge target |
|---------------------------|---------------------------------------|-----------------------------------------------------------------|--------------|
| `issue/<number>-<slug>`   | Standing-priority implementation work | `git checkout -b issue/<...>` (router creates/syncs automatically) | `develop` (squash) |
| `feature/<slug>`          | Parallel experiments / rehearsals     | `npm run feature:branch:dry -- <slug>` (live helper coming soon) | `develop` (squash) |
| `release/<version>`       | Release preparation                   | `npm run release:branch -- <version>`                            | PR to `main` |

- Keep branches short-lived and delete them after merge (repository default).
- Rebase feature and issue branches on `develop` until the queue is green; avoid merge commits entirely.

## Enforcement Layers

### Local helpers
- `tools/priority/create-pr.mjs` refuses PRs opened from `develop`/`main`, forcing contributors onto feature/issue
  branches.
- Dry-run helpers (`npm run feature:branch:dry`, `npm run feature:finalize:dry`) rehearse branch creation/finalization
  and emit metadata under `tests/results/_agent/feature/`.
- `npm run priority:pr` pushes the current branch to your fork and opens a PR targeting `develop`, keeping the linear
  history contract intact.

### CI guardrails
- `.github/workflows/merge-history.yml` blocks merge commits on PRs (release branches excluded).
- The standing-priority router keeps `priority:policy`, `hooks:multi`, and `PrePush-Checks.ps1` near the top to ensure
  linting, branch protection validation, and hook parity stay green.
- `Validate` runs `priority:handoff-tests` automatically for heads that start with `feature/`, enforcing leak-sensitive
  suites before parallel work merges.

### GitHub rulesets
| Ruleset ID | Scope                | Highlights                                                                                   |
|------------|----------------------|----------------------------------------------------------------------------------------------|
| `8811898`  | `refs/heads/develop` | Linear history required, squash-only merges, checks: `guard`, `lint`, `fixtures`, `session-index`, `issue-snapshot`, `Workflows Lint / lint (pull_request)` |
| `8614140`  | `refs/heads/main`    | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=5 entries, 5-minute quiet window). Required checks: `lint`, `pester`, `vi-binary-check`, `vi-compare`. Requires one approving review with resolved threads. |
| `8614172`  | `refs/heads/release/*` | No merge queue; protects against force-push/deletion. Required checks: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`. Requires one approving review with resolved threads. |

`node tools/npm/run-script.mjs priority:policy` queries these rulesets and fails if the live configuration drifts from
`tools/priority/policy.json`; run it whenever you adjust protections.

## Prescriptive Protection Settings

Keep GitHub’s live protections in lockstep with the repository contract below. Any delta should either be reverted or
checked into `tools/priority/policy.json` so `priority:policy` stays authoritative.

- `node tools/npm/run-script.mjs priority:policy` – verify only (fails on drift).
- `node tools/npm/run-script.mjs priority:policy -- --apply` – pushes the manifest configuration back to GitHub (branch
  protections + rulesets); rerun without `--apply` afterward to confirm parity.
- The Validate workflow runs the verify-only command on every PR targeting `develop`; fix GitHub settings or update
  `tools/priority/policy.json` before re-running CI when it fails.

### `develop`
- **Merge strategy**: squash only (enforce linear history, disable merge commits).
- **Required checks**: `guard`, `lint`, `fixtures`, `session-index`, `issue-snapshot`,
  `Workflows Lint / lint (pull_request)`.
- **Admin bypass**: leave disabled; administrators should only intervene when `priority:policy` confirms parity.
- **Quick reapply**:
  ```powershell
  gh api repos/$REPO/branches/develop/protection -X PUT `
    -f required_linear_history.enabled=true `
    -f required_status_checks.strict=true `
    -f required_status_checks.contexts[]='guard' `
    -f required_status_checks.contexts[]='lint' `
    -f required_status_checks.contexts[]='fixtures' `
    -f required_status_checks.contexts[]='session-index' `
    -f required_status_checks.contexts[]='issue-snapshot' `
    -f required_status_checks.contexts[]='Workflows Lint / lint (pull_request)' `
    -H "Accept: application/vnd.github+json"
  ```

### `main`
- **Ruleset**: `8614140` (repository ruleset, scope `refs/heads/main`).
- **Allowed merges**: queue-managed squash (`merge queue` with `merge_method=SQUASH`); disallow direct fast-forwards.
- **Merge queue parameters**:
  - `grouping_strategy=ALLGREEN`
  - `max_entries_to_build=5`, `min_entries_to_merge=1`, `max_entries_to_merge=5`
  - `min_entries_to_merge_wait_minutes=5`
  - `check_response_timeout_minutes=60`
- **Required checks**: `lint`, `pester`, `vi-binary-check`, `vi-compare`.
- **Approval policy**: ≥1 review; dismiss stale reviews on push; require thread resolution.
- **Quick verification**:
  ```powershell
  gh api repos/$REPO/rulesets/8614140 --jq '{target,conditions,parameters: [.rules[]|{type,parameters}]}'
  ```
  Update via the UI or `gh ruleset update` if any parameter deviates from `tools/priority/policy.json`.

### `release/*`
- **Ruleset**: `8614172` (scope `refs/heads/release/*`).
- **Required checks**: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`.
- **Approvals**: ≥1 review, stale review dismissal enabled, enforce thread resolution.
- **Merge queue**: intentionally disabled; rely on manual review + required checks.
- **Maintenance tip**: revisit after each release cycle to ensure the workflow matrix still emits the expected check
  names.

## Merge Queue Workflow (main)
1. Ensure the PR targets `main` (typically a release PR) and all required checks (`lint`, `pester`, `vi-binary-check`,
   `vi-compare`) are green on the latest commit.
2. Click **Enable auto-merge**, choose **Merge queue (squash)**, and confirm at least one approval is present with all
   review threads resolved (queue enforces this).
3. Monitor `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/merge-queue/main` as the synthetic queue
   run executes. GitHub stages up to five entries, reruns required checks with the queue tip, and enforces a
   five-minute quiet period before merging.
4. If the run fails or new commits land, the queue ejects the entry back to the PR. Address the failure, rerun the
   relevant check (`priority:validate`, `Validate` workflow, or manual reruns), and re-enable the queue.

## Troubleshooting
- **Merge history guard failure** – Rebase the branch (`git fetch origin && git rebase origin/develop`) and force push
  with `--force-with-lease`.
- **Queue saturation or slow merges** – Review the merge queue page linked above to see pending entries and their
  required checks. Cancel stale queue jobs from the PR if necessary.
- **Policy drift detected by `priority:policy`** – Align GitHub settings with `tools/priority/policy.json` (update the
  JSON if the new configuration is intentional), then rerun the helper.
- **Release artifacts stale** – For release branches, rerun `priority:release` helpers or the finalize workflow to
  regenerate `tests/results/_agent/release/*` snapshots before broadcasting status updates.

## References
- `tools/priority/create-pr.mjs`
- `tools/priority/check-policy.mjs`
- `.github/workflows/merge-history.yml`
- GitHub Docs: [About merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/about-merge-queue)
