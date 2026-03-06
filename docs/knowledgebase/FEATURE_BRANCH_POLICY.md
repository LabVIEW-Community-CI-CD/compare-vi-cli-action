<!-- markdownlint-disable-next-line MD041 -->
# Feature Branch Enforcement & Merge Queue

_Last updated: 2026-03-05 (standing priority #719)._ 

## Purpose

Serve as the canonical quick reference for how contributors branch, validate, and promote work while satisfying the
standing GitHub protection rules (including queue-managed `develop` and `main`).

## Branch Expectations

| Branch pattern            | Purpose                               | Creation helper                                                 | Merge target |
|---------------------------|---------------------------------------|-----------------------------------------------------------------|--------------|
| `issue/<number>-<slug>`   | Standing-priority implementation work | `git checkout -b issue/<...>` (router creates/syncs automatically) | `develop` (squash) |
| `feature/<slug>`          | Parallel experiments / rehearsals     | `node tools/npm/run-script.mjs feature:branch:dry -- <slug>` (live helper coming soon) | `develop` (squash) |
| `release/<version>`       | Release preparation                   | `node tools/npm/run-script.mjs release:branch -- <version>`                            | PR to `main` |

- Keep branches short-lived and delete them after merge (repository default).
- Rebase feature and issue branches on `develop` until the queue is green; avoid merge commits entirely.

## Enforcement Layers

### Local helpers
- `tools/priority/create-pr.mjs` refuses PRs opened from `develop`/`main`, forcing contributors onto feature/issue
  branches.
- Standing-priority repo/upstream detection is owner-agnostic (uses `GITHUB_REPOSITORY`, then git remotes).
  Set `AGENT_PRIORITY_UPSTREAM_REPOSITORY=<owner/repo>` (or `AGENT_UPSTREAM_REPOSITORY`) to force upstream lookup
  when remotes are non-standard.
- Dry-run helpers (`node tools/npm/run-script.mjs feature:branch:dry`, `node tools/npm/run-script.mjs feature:finalize:dry`) rehearse branch creation/finalization
  and emit metadata under `tests/results/_agent/feature/`.
- `node tools/npm/run-script.mjs priority:pr` pushes the current branch to your fork and opens a PR targeting `develop`, keeping the linear
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
- `.github/workflows/policy-guard-upstream.yml` (triggered via `pull_request_target`, `merge_group`, and schedule) checks
  out the PR head with the upstream repository token and re-runs `priority:policy`, guaranteeing that branch protection
  rules are enforced even when the lint job skips in fork contexts. Its status
  (`Policy Guard (Upstream) / policy-guard`) is required on `develop`, `main`, and `release/*`.
- Upstream policy guard runs in strict mode (`--fail-on-skip`), so reduced token scope is treated as a failing gate
  rather than a pass-through skip.
- Policy guard/sync workflows now resolve token candidates in order (`secrets.GH_TOKEN`, `secrets.GITHUB_TOKEN`,
  `github.token`) via `tools/priority/Resolve-PolicyToken.ps1` and require an admin-capable token for deterministic
  branch-protection checks.
- Branch protection verification requires canonical check context names exactly as declared in policy files.
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
| `8811898`  | `refs/heads/develop` | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=5 entries, 5-minute quiet window). Required checks: `lint`, `fixtures`, `session-index`, `issue-snapshot`, `semver`, `Policy Guard (Upstream) / policy-guard`, `hook-parity (windows-latest)`, `hook-parity (ubuntu-latest)`, `vi-history-scenarios-linux`. |
| `8614140`  | `refs/heads/main`    | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=5 entries, 5-minute quiet window). Required checks: `lint`, `pester`, `vi-binary-check`, `vi-compare`, `Policy Guard (Upstream) / policy-guard`. Required approving reviews: `0`. |
| `8614172`  | `refs/heads/release/*` | No merge queue; protects against force-push/deletion. Required checks: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`, `Policy Guard (Upstream) / policy-guard`. Required approving reviews: `0`. |

`node tools/npm/run-script.mjs priority:policy` queries these rulesets and fails if the live configuration drifts from
`tools/priority/policy.json`; run it whenever you adjust protections.

## Prescriptive Protection Settings

Keep GitHub’s live protections in lockstep with the repository contract below. Any delta should either be reverted or
checked into `tools/priority/policy.json` so `priority:policy` stays authoritative.

- `node tools/npm/run-script.mjs priority:policy` – verify only (fails on drift).
- `node tools/npm/run-script.mjs priority:policy:sync` – verify via the policy-sync wrapper with machine-readable report output.
- `node tools/npm/run-script.mjs priority:policy -- --apply` – pushes the manifest configuration back to GitHub (branch
  protections + rulesets); rerun without `--apply` afterward to confirm parity.
- `node tools/npm/run-script.mjs priority:policy:apply` – apply via the wrapper (`Sync-BranchProtectionPolicy.ps1`) and emit report summary.
- Policy guard workflows invoke sync in strict mode (`-FailOnSkip`) so permission shortfalls fail CI.
- The Validate workflow runs the verify-only command on every PR and queue run targeting `develop`; fix GitHub settings or update
  `tools/priority/policy.json` before re-running CI when it fails.

### Runbook container canary policy note

- The runbook container lane is currently a **non-required canary** and is intentionally excluded from the develop
  required-check contract until a separate promotion decision is accepted.
- Promotion/rollback decision criteria and evidence requirements are defined in
  `docs/RUNBOOK_CONTAINER_LANE_PROMOTION_POLICY.md`.

### `develop`
- **Merge strategy**: queue-managed squash with linear history enforced; merge commits disabled.
- **Required checks**: `lint`, `fixtures`, `session-index`, `issue-snapshot`, `semver`,
  `Policy Guard (Upstream) / policy-guard`,
  `hook-parity (windows-latest)`, `hook-parity (ubuntu-latest)`, `vi-history-scenarios-linux`.
- **Admin bypass**: leave disabled; administrators should only intervene when `priority:policy` confirms parity.
- **Reapply**: Use `node tools/npm/run-script.mjs priority:policy -- --apply` to push the manifest configuration when drift is detected.

#### Requirements verification gate (local runbook)

- Generate and evaluate the gate summary locally:

  ```powershell
  pwsh -NoLogo -NonInteractive -NoProfile -File tools/Verify-RequirementsGate.ps1 \
    -TestsPath tests \
    -ResultsRoot tests/results \
    -OutDir tests/results/_agent/verification \
    -BaselinePolicyPath tools/policy/requirements-verification-baseline.json
  ```

- Run focused regression tests for baseline pass/fail logic:

  ```powershell
  ./Invoke-PesterTests.ps1 -IncludePatterns 'RequirementsVerificationGate.Tests.ps1'
  ```

- Validate the gate output contract schema explicitly:

  ```powershell
  pwsh -NoLogo -NonInteractive -NoProfile -File tools/Invoke-JsonSchemaLite.ps1 \
    -JsonPath tests/results/_agent/verification/verification-summary.json \
    -SchemaPath docs/schemas/requirements-verification-v1.schema.json
  ```

- Assert check naming drift guard (workflow + policy contract alignment):

  ```powershell
  pwsh -NoLogo -NonInteractive -NoProfile -File tools/Assert-RequirementsVerificationCheckContract.ps1
  ```

- Validate branch-protection helper contract deterministically (uses the canonical
  `tools/policy/branch-required-checks.json` develop mapping):

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path 'tests/SessionIndex.BranchProtection.Tests.ps1','tests/GetBranchProtectionRequiredChecks.Tests.ps1','tests/RequirementsVerificationCheckContract.Tests.ps1' -Output Detailed"
  ```

- Validate policy helper drift coverage for develop and release required-check contracts:

  ```powershell
  node --test tools/priority/__tests__/check-policy-apply.test.mjs
  ```

- Validate merge-mode selection guardrails (`develop` direct merge vs `main` merge-queue/auto):

  ```powershell
  node --test tools/priority/__tests__/merge-sync-pr.test.mjs
  ```

- Generate a merge helper dry-run summary with policy trace metadata (`policyTrace.mergeQueueBranches`):

  ```powershell
  node tools/priority/merge-sync-pr.mjs --pr <number> --repo <owner/repo> --dry-run --summary-path tests/results/_agent/priority/merge-sync-dry-run.json
  ```

- Inspect stable summary payload fields (`selectedMode`, `finalMode`, `prState.baseRefName`):

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object schema,selectedMode,finalMode,@{Name='baseRefName';Expression={$_.prState.baseRefName}},policyTrace | ConvertTo-Json -Depth 6"
  ```

- Inspect reason diagnostics (`selectedReason`, `finalReason`) for queue/non-queue
  troubleshooting:

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object selectedMode,selectedReason,finalMode,finalReason | ConvertTo-Json -Depth 4"
  ```

- Inspect unknown-state reason output explicitly:

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object selectedMode,selectedReason,@{Name='mergeState';Expression={$_.prState.mergeStateStatus}},@{Name='baseRef';Expression={$_.prState.baseRefName}} | ConvertTo-Json -Depth 4"
  ```

- Inspect fallback reason mapping output (`merge-state-unspecified`) when merge
  state is absent:

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object selectedMode,selectedReason,@{Name='fallbackExpected';Expression={'merge-state-unspecified'}},@{Name='baseRef';Expression={$_.prState.baseRefName}} | ConvertTo-Json -Depth 4"
  ```

- Inspect minimal fallback diagnostics fields (reason + mergeability context):

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object selectedReason,@{Name='mergeState';Expression={$_.prState.mergeStateStatus}},@{Name='mergeable';Expression={$_.prState.mergeable}},@{Name='baseRef';Expression={$_.prState.baseRefName}} | ConvertTo-Json -Depth 4"
  ```

`prState.baseRefName` is normalized to lowercase branch names (for example,
`refs/heads/Main` → `main`) before mode diagnostics are emitted.

- Inspect retry-flow transitions (`selectedMode`, `finalMode`, `attempts`) from the
  dry-run summary:

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object selectedMode,finalMode,finalReason,attempts | ConvertTo-Json -Depth 8"
  ```

- Optional parity run for non-LV checks using the published tools image:

  ```powershell
  $env:COMPAREVI_TOOLS_IMAGE = 'ghcr.io/<owner>/comparevi-tools:latest'
  pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage
  ```

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
- **Required checks**: `lint`, `pester`, `vi-binary-check`, `vi-compare`, `Policy Guard (Upstream) / policy-guard`.
- **Workflow triggers**: Ensure those required checks run on both `pull_request` and `merge_group` so queued entries can merge.
- **Approval policy**: 0 required reviews; stale review dismissal and thread resolution are not enforced.
- **Quick verification**:
  ```powershell
  gh api repos/$REPO/rulesets/8614140 --jq '{name,enforcement,conditions,rules:[.rules[]|{type,parameters}]}'
  ```
  Update via the UI or with the REST API (for example, `gh api repos/$REPO/rulesets/8614140 -X PATCH --input payload.json`)
  if any parameter deviates from `tools/priority/policy.json`.

### `release/*`
- **Ruleset**: `8614172` (scope `refs/heads/release/*`).
- **Required checks**: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`, `Policy Guard (Upstream) / policy-guard`.
- **Approvals**: 0 required reviews; stale review dismissal remains enabled.
- **Merge queue**: intentionally disabled; rely on manual review + required checks.
- **Maintenance tip**: revisit after each release cycle to ensure the workflow matrix still emits the expected check
  names.

## Merge Queue Workflow (develop/main)
Prereq: All required checks for queue-managed branches must execute on both `pull_request` and `merge_group`. Use the YAML snippet above
to confirm each workflow includes both triggers.

1. Ensure the PR targets a queue-managed branch (`develop` or `main`) and all required checks for that branch are green
   on the latest commit.
2. Click **Merge when ready** (queue-managed **squash**). No reviewer approval is required under the current policy.
3. Monitor the corresponding queue page (`/queue/develop` or `/queue/main`). GitHub stages entries, reruns the required
   checks on the merge group tip, and waits up to your configured minimum group size wait time before merging smaller
   groups.
4. If the run fails or new commits land, the queue ejects the entry back to the PR. Address the failure, rerun the
   relevant check (`priority:validate`, `Validate` workflow, or manual reruns), and re-enable the queue.
5. For autonomous queueing, run `node tools/npm/run-script.mjs priority:queue:supervisor -- --dry-run` first, then
   `--apply` when trunk health is green. The supervisor enforces required checks, dependency ordering, and queue caps.
6. Autonomous merge tooling now requires upstream-owned PR heads. Fork-headed PRs are intentionally ineligible for
   `priority:queue:supervisor` and `priority:merge-sync`; mirror the branch to upstream and open the PR from the
   upstream-owned branch before queueing.
7. Validate deployment evidence is run-scoped: `priority:deployment:assert` verifies the `validation` environment using
   the current workflow run id, fails when the newest deployment is owned by another run, and tolerates terminal
   `inactive` statuses only when they follow a successful deployment for the same run.

### PR Metadata Contract (queue supervisor)
- `Coupling: independent|soft|hard` (default: `independent`)
- `Depends-On: #<issue-or-pr>[,#<issue-or-pr>]`
- Exclusion labels:
  - `do-not-queue`
  - `queue-blocked`
  - `queue-quarantine`

## Troubleshooting
- **Merge history guard failure** – Rebase the branch (`git fetch origin && git rebase origin/develop`) and force push
  with `--force-with-lease`.
- **Queue saturation or slow merges** – Review the merge queue page linked above to see pending entries and their
  required checks. Cancel stale queue jobs from the PR if necessary.
- **No standing-priority issue** – unattended flows should run `priority:sync:strict`; this fails fast and writes
  `tests/results/_agent/issue/no-standing-priority.json` instead of looping.
- **Policy drift detected by `priority:policy`** – Align GitHub settings with `tools/priority/policy.json` (update the
  JSON if the new configuration is intentional), then rerun the helper.
- **Policy guard auth failure (`Authorization unavailable` / `authenticated-no-admin`)** – verify and rotate upstream
  secrets with an admin-capable token:
  ```powershell
  $repo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { '<owner>/<repo>' }
  $token = (Get-Content C:\github_token.txt -Raw).Trim()
  gh api "repos/$repo" -H "Authorization: Bearer $token" --jq '.permissions.admin'
  $token | gh secret set GH_TOKEN --repo $repo
  $token | gh secret set GITHUB_TOKEN --repo $repo
  ```
- **Release artifacts stale** – For release branches, rerun `priority:release` helpers or the finalize workflow to
  regenerate `tests/results/_agent/release/*` snapshots before broadcasting status updates.

## References
- `tools/priority/create-pr.mjs`
- `tools/priority/check-policy.mjs`
- `.github/workflows/merge-history.yml`
- GitHub Docs: [About merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/about-merge-queue)
