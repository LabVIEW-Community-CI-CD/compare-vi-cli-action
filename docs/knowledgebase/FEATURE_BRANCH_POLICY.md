<!-- markdownlint-disable-next-line MD041 -->
# Feature Branch Enforcement & Merge Queue

| `develop` (live id may drift) | `refs/heads/develop` | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=20 entries, 1-minute quiet window). Required checks: `lint`, `fixtures`, `session-index`, `issue-snapshot`, `semver`, `Policy Guard (Upstream) / policy-guard`, `vi-history-scenarios-linux`, `agent-review-policy`, `hook-parity`, `commit-integrity`. Non-required hosted proof lanes may run alongside the queue contract, including `vi-history-scenarios-windows` on GitHub-hosted `windows-2022`. Copilot review settings are no longer enforced through policy; draft/ready review semantics are repo-owned and validated by `agent-review-policy`. |

## Purpose

Serve as the canonical quick reference for how contributors branch, validate, and promote work while satisfying the
standing GitHub protection rules (including queue-managed `develop` and `main`).

Canonical branch-role definitions now live in [docs/BRANCH_ROLE_CONTRACT.md](../BRANCH_ROLE_CONTRACT.md) and
[tools/policy/branch-classes.json](../../tools/policy/branch-classes.json). This page focuses on enforcement and
promotion behavior, not the branch-class source of truth.

## Branch Expectations

| Branch pattern | Purpose | Creation helper | Merge target |
|----------------|---------|-----------------|--------------|
| `issue/personal-<number>-<slug>` | Standing work on the personal authoring plane | `git checkout -b issue/personal-<...>` | `develop` (squash) |
| `issue/origin-<number>-<slug>` | Standing work on the org-fork review plane | `git checkout -b issue/origin-<...>` | `develop` (squash) |
| `issue/<number>-<slug>` | Upstream-native standing lanes only | `git checkout -b issue/<...>` | `develop` (squash) |
| `feature/<slug>` | Parallel experiments / rehearsals | `node tools/npm/run-script.mjs feature:branch:dry -- <slug>` (live helper coming soon) | `develop` (squash) |
| `release/<version>` | Release preparation | `node tools/npm/run-script.mjs release:branch -- <version>` | PR to `main` |

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
  selected dispatch remote (upstream-native lanes stay on `upstream`; same-owner fork lanes can target `origin`/`personal`)
  when it is absent before dispatching Validate. The helper refuses to push when the branch is dirty,
  when the ref resolves to a tag, or when the remote tip differs unless you also pass `--force-push-ok`
  (`VALIDATE_DISPATCH_PUSH=1` / `VALIDATE_DISPATCH_FORCE_PUSH=1` provide the same behaviour for automation).
- Fork-backed standing lanes now carry explicit lane-identity receipts instead of forcing later workers to rediscover
  provenance from branch names. The current identities are:
  - `upstream-standing`: canonical upstream lane with no fork plane
  - `fork-plane-branch`: fork execution plane with canonical upstream standing ownership
  - `fork-standing-mirror`: fork issue explicitly mirroring an upstream standing issue
- Recover these identities from:
  - `tests/results/_agent/issue/priority-pr-create-<remote>-<issue>.json`
  - `tests/results/_agent/issue/priority-validate-dispatch-<remote>-<issue>.json`
  Use those receipts for worker reuse and remote dispatch attribution instead of inferring identity from `issue/<...>`
  naming alone.

### CI guardrails
- `.github/workflows/merge-history.yml` blocks merge commits on PRs (release branches excluded).
- The standing-priority router keeps `priority:policy`, `hooks:multi`, and `PrePush-Checks.ps1` near the top to ensure
  linting, branch protection validation, and hook parity stay green.
- `Validate` includes a `Policy guard (branch protection)` step that runs `node tools/npm/run-script.mjs priority:policy`
  with the repository token when it is available. On fork PRs the step now detects the reduced token scope, logs that the
  upstream guard will run, and exits cleanly so community contributors are not blocked.
- `.github/workflows/policy-guard-upstream.yml` (triggered via `pull_request_target`, `merge_group`, and schedule) re-runs
  `priority:policy` so queue-required policy checks attach to PR heads and merge-queue merge groups using one canonical
  status context. Its status
  (`Policy Guard (Upstream) / policy-guard`) is required on `develop`, `main`, and `release/*`.
- Upstream policy guard runs in strict mode (`--fail-on-skip`), so reduced token scope is treated as a failing gate
  rather than a pass-through skip.
- Policy guard/sync workflows now resolve token candidates in order (`secrets.GH_TOKEN`, `secrets.GITHUB_TOKEN`,
  `github.token`) via `tools/priority/Resolve-PolicyToken.ps1` and require an admin-capable token for deterministic
  branch-protection checks.
- Branch protection verification requires canonical check context names exactly as declared in policy files.
- `Validate` runs `priority:handoff-tests` automatically for heads that start with `feature/`, enforcing leak-sensitive
  suites before parallel work merges.
- **Important:** Required checks for queued branches must run on both PR and `merge_group` contexts (for trusted-only
  checks, use `pull_request_target` + `merge_group`); otherwise the merge queue will eject entries. Ensure your workflows include:

  ```yaml
  on:
    pull_request: # or pull_request_target for trusted-only checks
    merge_group:
  ```

### GitHub rulesets
| Ruleset ID | Scope                | Highlights                                                                                   |
|------------|----------------------|----------------------------------------------------------------------------------------------|
| `develop` (live id may drift) | `refs/heads/develop` | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=5 entries, 1-minute quiet window). Required checks: `lint`, `fixtures`, `session-index`, `issue-snapshot`, `semver`, `Policy Guard (Upstream) / policy-guard`, `vi-history-scenarios-linux`, `agent-review-policy`, `hook-parity`, `commit-integrity`. Non-required hosted proof lanes may run alongside the queue contract, including `vi-history-scenarios-windows` on GitHub-hosted `windows-2022`. Copilot review settings are no longer enforced through policy; draft/ready review semantics are repo-owned and validated by `agent-review-policy`. |
| `8614140`  | `refs/heads/main`    | Merge queue enabled (`merge_method=SQUASH`, `grouping=ALLGREEN`, build queue <=5 entries, 1-minute quiet window). Required checks: `lint`, `pester`, `vi-binary-check`, `vi-compare`, `Policy Guard (Upstream) / policy-guard`, `commit-integrity`. Required approving reviews: `0`. |
| `8614172`  | `refs/heads/release/*` | No merge queue; protects against force-push/deletion. Required checks: `lint`, `pester`, `publish`, `vi-binary-check`, `vi-compare`, `mock-cli`, `Policy Guard (Upstream) / policy-guard`. Required approving reviews: `0`. |

`node tools/npm/run-script.mjs priority:policy` queries these rulesets and fails if the live configuration drifts from
`tools/priority/policy.json`; run it whenever you adjust protections.
`node tools/npm/run-script.mjs priority:policy:snapshot` now also emits `state.copilotReview`, which must show
`rulesetCopilotCodeReviewPresent = false` for the local CLI review contract. The repository-level
"Automatic request Copilot review" setting is still a manual settings-page verification point because GitHub's REST
ruleset/branch-protection APIs do not expose that toggle directly.

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
  `vi-history-scenarios-linux`, `agent-review-policy`, `hook-parity`, `commit-integrity`.
- **Non-required hosted proof**: `vi-history-scenarios-windows` may run on GitHub-hosted
  `windows-2022` to validate `nationalinstruments/labview:2026q1-windows`. Agents may
  dispatch that hosted lane while manually running the Linux or Windows Docker Desktop/WSL2 lanes on this host.
- **Admin bypass**: leave disabled; administrators should only intervene when `priority:policy` confirms parity.
- **Reapply**: Use `node tools/npm/run-script.mjs priority:policy -- --apply` to push the manifest configuration when drift is detected.

### Fork `develop`
- **Branch class**: mirror rail, not a human integration branch.
- **Force alignment**: fork `develop` allows force-push so upstream parity can be restored without remediation PR churn.
- **Fork syncing**: stays disabled in the checked-in policy until GitHub's fork-sync behavior is proven deterministic for this rail.
- **Authority split**: upstream `develop` remains the protected integration rail; the fork override only changes fork-hosted branch protection behavior.

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
    -JsonPath tests/results/_agent/verification/docker-review-loop-summary.json \
    -SchemaPath docs/schemas/docker-tools-parity-agent-verification-v1.schema.json
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

- Inspect repository-aware merge method selection (`mergeMethod`,
  `mergeMethodSelection.requestedMethod`, `mergeMethodSelection.effectiveMethod`):

  ```powershell
  pwsh -NoLogo -NoProfile -Command "Get-Content tests/results/_agent/priority/merge-sync-dry-run.json -Raw | ConvertFrom-Json | Select-Object mergeMethod,@{Name='requestedMethod';Expression={$_.mergeMethodSelection.requestedMethod}},@{Name='requestedSource';Expression={$_.mergeMethodSelection.requestedSource}},@{Name='effectiveMethod';Expression={$_.mergeMethodSelection.effectiveMethod}},@{Name='methodReason';Expression={$_.mergeMethodSelection.reason}} | ConvertTo-Json -Depth 6"
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

- Merge-sync, the Copilot queue gate, `security-intake`, and `check-policy` now resolve local GitHub auth in this
  order before live review lookups:
  1. `GH_TOKEN`
  2. `GITHUB_TOKEN`
  3. `GH_TOKEN_FILE`
  4. `GITHUB_TOKEN_FILE`
  5. standard host token file fallback (`C:\github_token.txt` on Windows,
     `/mnt/c/github_token.txt` on non-Windows host planes)
  The gate receipt records this under `auth.source` and classifies a missing
  live token source as `auth.failureClass = "auth-unavailable"` instead of a
  generic data error.

### `main`
- **Ruleset**: `8614140` (repository ruleset, scope `refs/heads/main`).
- **Allowed merges**: queue-managed squash enforced by the `merge_queue` rule (`merge_method=SQUASH`); direct merges and
  fast-forwards are disallowed while the queue is active.
- **Merge queue parameters** (ruleset API terms; UI "Only merge non-failing pull requests" corresponds to
  `grouping_strategy=ALLGREEN`):
  - `grouping_strategy=ALLGREEN`
  - `max_entries_to_build=5`, `min_entries_to_merge=1`, `max_entries_to_merge=5`
  - `min_entries_to_merge_wait_minutes=1`
  - `check_response_timeout_minutes=60`
- **Required checks**: `lint`, `pester`, `vi-binary-check`, `vi-compare`, `Policy Guard (Upstream) / policy-guard`, `commit-integrity`.
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
   For `develop`, keep the PR in **Draft** if you need the explicit escape hatch from Copilot review while iterating.
   Ready PRs must wait for `agent-review-policy`, which now converges in one of these deterministic ways:
   - when the repo is using hosted GitHub review discovery, the first Copilot review lands during the workflow's bounded polling window and reports no actionable current-head threads
   - a follow-up push on an already reviewed PR leaves zero actionable current-head Copilot threads, allowing a stale-but-clean follow-up head
   - when the repo is using the local-only `draft-only-explicit` strategy, the hosted gate records that no ready-phase GitHub Copilot review is required and does not poll for a missing hosted review run
2. Click **Merge when ready** (queue-managed **squash**). No reviewer approval is required under the current policy.
3. Monitor the corresponding queue page (`/queue/develop` or `/queue/main`). GitHub stages entries, reruns the required
   checks on the merge group tip, and waits up to your configured minimum group size wait time before merging smaller
   groups.
4. If the run fails or new commits land, the queue ejects the entry back to the PR. Address the failure, rerun the
   relevant check (`priority:validate`, `Validate` workflow, or manual reruns), and re-enable the queue.
   Queue-safe cleanup note: `priority:merge-sync` does not send `gh pr merge --delete-branch` on queue-managed bases.
   Without `--keep-branch`, direct merges still use inline branch deletion, but queue-managed or retried `--auto`
   promotions record `branchCleanup` in `tests/results/_agent/queue/merge-sync-<pr>.json` and use post-merge API
   deletion once the merge materializes. When the PR remains queued after the current helper turn, `priority:queue:supervisor`
   reconciles that deferred cleanup and records the outcome under `deferredBranchCleanup` in
   `tests/results/_agent/queue/queue-supervisor-report.json`.
   When a queued `develop` PR needs a base refresh or a safe amendment turn, run the dedicated helper from a clean checkout of that PR head:
   `node tools/npm/run-script.mjs priority:queue:refresh -- --pr <number> --repo $REPO`. It dequeues the PR through
   GraphQL, then either rebases the checked-out branch onto current `develop` or, with `--skip-rebase`, force-pushes
   the already-checked-out PR head as-is for queued amendment flows. It then re-arms queue admission via
   `priority:merge-sync` and writes `tests/results/_agent/queue/queue-refresh-<pr>.json` as the machine-readable receipt.
5. For autonomous queueing, run `node tools/npm/run-script.mjs priority:queue:supervisor -- --dry-run` first, then
   `--apply` when trunk health is green. The supervisor enforces required checks, dependency ordering, and queue caps.
   Use `QUEUE_AUTOPILOT_MAX_INFLIGHT` for cap tuning and keep `QUEUE_AUTOPILOT_ADAPTIVE_CAP=1`
   (`QUEUE_AUTOPILOT_MIN_INFLIGHT` floor) so enqueue pressure self-throttles under runtime saturation.
   Hosted cadence runs every 5 minutes, with immediate `--apply` runs triggered by
   `Validate` / `Policy Guard (Upstream)` completions on `develop`.
   `tests/results/_agent/queue/queue-supervisor-report.json` also carries `workerOccupancy`, sourced from
   `tests/results/_agent/runtime/delivery-agent-state.json`, so standing throughput reports can distinguish worker-slot
   saturation from merge-queue occupancy.
6. Treat merge-queue utilization as a throughput target, not only as a branch-protection setting. The checked-in
   contract lives in `tools/policy/merge-queue-utilization-target.json`, and the measurable scorecard is:

   ```powershell
   node tools/npm/run-script.mjs priority:throughput:scorecard
   ```

   Current target on `develop`:
   - keep at least `2` ready PRs available for queue admission
   - warn when active queue occupancy falls below `50%` of `effectiveMaxInflight`
   - aim for `100%` occupancy when the queue is active
   - treat paused queues as operationally exempt until the pause is lifted

   The scorecard writes `tests/results/_agent/throughput/throughput-scorecard.json` and now emits:
   - `mergeQueueUtilization.target`
   - `mergeQueueUtilization.observed`
   - `mergeQueueUtilization.status`
   - `mergeQueueUtilization.reasons`

   Immediate reason codes:
   - `merge-queue-ready-inventory-below-floor`
   - `merge-queue-occupancy-below-floor`
   The policy snapshot report at `tests/results/_agent/policy/policy-state-snapshot.json` also includes
   `state.mergeQueueContinuity`, which compares the checked-in `develop` batch settings against a hypothetical
   single-entry merge-group proposal and records the current recommendation without changing `tools/policy/policy.json`.
7. Delivery-agent receipt follow-up: project at least these merge-queue signals into runtime receipts once the
   queue-orchestration lane takes them on:
   - `readyPrInventory`
   - `effectiveMaxInflight`
   - `mergeQueueOccupancyRatio`
   - `mergeQueueReadyInventoryFloor`
   - latest `mergeQueueUtilization.reasons`
8. Autonomous merge tooling accepts clean PRs from approved fork planes as well as upstream-owned branches. Use
   `AGENT_PRIORITY_ACTIVE_FORK_REMOTE=origin|personal` (or `priority:pr -- --head-remote ...`) so the PR head owner is
   explicit, then let `priority:queue:supervisor` / `priority:merge-sync` enqueue the upstream PR directly instead of
   mirroring branches back to upstream first.
9. Standard `Validate` PR and merge-queue runs are machine-gated only: they do not use a protected `validation`
   deployment or require environment approval. Protected environment approvals are reserved for release/promotion
   flows (`production`, `monthly-stability-release`).

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
- **Standing-priority lane drift** – unattended flows should run `priority:sync:lane`; this fails fast when there is no
  standing issue or when multiple issues are labeled standing-priority, and writes deterministic diagnostics:
  `tests/results/_agent/issue/no-standing-priority.json` and
  `tests/results/_agent/issue/multiple-standing-priority.json`. When the
  repository is truly idle, the no-standing report uses `reason = queue-empty`
  and `openIssueCount = 0`; agents should treat that as an intake gap, not as a
  mislabeled standing issue.
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
  $token | gh secret set GH_TOKEN --repo $repo --app dependabot
  ```
  Dependabot-triggered workflow runs do not inherit the Actions secret scope automatically; keep the Dependabot
  `GH_TOKEN` secret aligned with the upstream Actions secret when policy guard must run on Dependabot PRs.
- **Release artifacts stale** – For release branches, rerun `priority:release` helpers or the finalize workflow to
  regenerate `tests/results/_agent/release/*` snapshots before broadcasting status updates.

## References
- `tools/priority/create-pr.mjs`
- `tools/priority/check-policy.mjs`
- `.github/workflows/merge-history.yml`
- GitHub Docs: [About merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/about-merge-queue)
