<!-- markdownlint-disable-next-line MD041 -->
# Feature Branch Enforcement & Merge Queue

_Last updated: 2025-10-22 (standing priority #293)._ 

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
- `node tools/npm/run-script.mjs priority:validate -- --ref <branch> --push-missing` publishes the branch to the
  upstream remote (when it is absent) before dispatching Validate. The helper refuses to push when the branch is dirty,
  when the ref resolves to a tag, or when the upstream tip differs unless you also pass `--force-push-ok`
  (`VALIDATE_DISPATCH_PUSH=1` / `VALIDATE_DISPATCH_FORCE_PUSH=1` provide the same behaviour for automation).

### CI guardrails
- `.github/workflows/merge-history.yml` blocks merge commits on PRs (release branches excluded).
- The standing-priority router keeps `priority:policy`, `hooks:multi`, and `PrePush-Checks.ps1` near the top to ensure
  linting, branch protection validation, and hook parity stay green.
- `Validate` includes a `Policy guard (branch protection)` step that runs `node tools/npm/run-script.mjs priority:policy`
  with the repository token when it is available. On fork PRs the step now detects the reduced token scope, logs that the
  upstream guard will run, and exits cleanly so community contributors are not blocked.
- `.github/workflows/policy-guard-upstream.yml` (triggered via `pull_request_target`) checks out the PR head with the
  upstream repository token and re-runs `priority:policy`, guaranteeing that branch protection rules are enforced even
  when the lint job skips in fork contexts. Its status (`Policy Guard (Upstream) / policy-guard`) is required on
  `develop`, `main`, and `release/*`.
- `Validate` runs `priority:handoff-tests` automatically for heads that start with `feature/`, enforcing leak-sensitive
  suites before parallel work merges.
- **Important:** Required checks for queued branches must run on both the `pull_request` and `merge_group` events;
  otherwise the merge queue will eject entries. Ensure your workflows include:

  ```yaml
  on:
    pull_request:
    merge_group:
  ```

### GitHub rulesets
| Ruleset ID | Scope                | Highlights                                                                                   |
|------------|----------------------|----------------------------------------------------------------------------------------------|
| `8811898`  | `refs/heads/develop` | Linear history required, squash-only merges, checks: `guard`, `lint`, `fixtures`, `session-index`, `issue-snapshot`, `Policy Guard (Upstream) / policy-guard` |
| `8614140`  | `refs/heads/main`    | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=5 entries, 5-minute quiet window). Required checks: `lint`, `pester`, `vi-binary-check`, `vi-compare`, `Policy Guard (Upstream) / policy-guard`. Requires one approving review with resolved threads. |
| `8614172`  | `refs/heads/release/*` | No merge queue; protects against force-push/deletion. Required checks: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`, `Policy Guard (Upstream) / policy-guard`. Requires one approving review with resolved threads. |

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
  `Policy Guard (Upstream) / policy-guard`.
- **Admin bypass**: leave disabled; administrators should only intervene when `priority:policy` confirms parity.
- **Reapply**: Use `node tools/npm/run-script.mjs priority:policy -- --apply` to push the manifest configuration when drift is detected.

### `main`
- **Ruleset**: `8614140` (repository ruleset, scope `refs/heads/main`).
- **Allowed merges**: queue-managed squash enforced by the `merge_queue` rule (`merge_method=SQUASH`); direct merges and
  fast-forwards are disallowed while the queue is active.
- **Merge queue parameters** (ruleset API terms; UI "Only merge non-failing pull requests" corresponds to
  `grouping_strategy=ALLGREEN`):
  - `grouping_strategy=ALLGREEN`
  - `max_entries_to_build=5`, `min_entries_to_merge=1`, `max_entries_to_merge=5`
  - `min_entries_to_merge_wait_minutes=5`
  - `check_response_timeout_minutes=60`
- **Required checks**: `lint`, `pester`, `vi-binary-check`, `vi-compare`.
- **Workflow triggers**: Ensure those required checks run on both `pull_request` and `merge_group` so queued entries can merge.
- **Approval policy**: >= 1 review; dismiss stale reviews on push; require thread resolution.
- **Quick verification**:
  ```powershell
  gh api repos/$REPO/rulesets/8614140 --jq '{name,enforcement,conditions,rules:[.rules[]|{type,parameters}]}'
  ```
  Update via the UI or with the REST API (for example, `gh api repos/$REPO/rulesets/8614140 -X PATCH --input payload.json`)
  if any parameter deviates from `tools/priority/policy.json`.

### `release/*`
- **Ruleset**: `8614172` (scope `refs/heads/release/*`).
- **Required checks**: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`.
- **Approvals**: >= 1 review, stale review dismissal enabled, enforce thread resolution.
- **Merge queue**: intentionally disabled; rely on manual review + required checks.
- **Maintenance tip**: revisit after each release cycle to ensure the workflow matrix still emits the expected check
  names.

## Merge Queue Workflow (main)
Prereq: All required checks for `main` must execute on both `pull_request` and `merge_group`. Use the YAML snippet above
to confirm each workflow includes both triggers.

1. Ensure the PR targets `main` (typically a release PR) and all required checks (`lint`, `pester`, `vi-binary-check`,
   `vi-compare`) are green on the latest commit.
2. Click **Merge when ready** (queue-managed **squash**). Ensure >= 1 approval and all review threads are resolved; the
   queue enforces both before merging.
3. Monitor `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/queue/main`. GitHub stages entries, reruns
   the required checks on the merge group tip, and waits up to your configured minimum group size wait time before
   merging smaller groups.
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
