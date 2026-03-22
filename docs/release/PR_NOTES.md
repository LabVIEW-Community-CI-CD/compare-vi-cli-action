<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4-rc.1 - PR Notes Helper

Reference sheet for refining the `v0.6.4-rc.1` release PR and draft release.
This RC is about hardening the hosted-first release conductor, keeping the
template conveyor pinned and green, and proving the repo can reach a truthful
queue-empty state before the template pivot.

## 1. Summary

Release `v0.6.4-rc.1` focuses on four themes:

- **Hosted-first release gating**: the release conductor now aligns `release/*`
  policy, live GitHub rulesets, and the actual RC PR gate so finalize depends
  on the checks that really matter.
- **Template conveyor as a pinned dependency**:
  `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate@v0.1.1` is treated as an
  immutable dependency and is revalidated through the cookiecutter conveyor.
- **Continuity/control-plane hardening**: standing rotation, detached
  bootstrap, linked worktree release helpers, and queue-empty proof surfaces
  now support an unattended RC cut.
- **Capital deployment telemetry**: PR/issue spend, invoice-turn attribution,
  and template verification cost provenance stay visible while the RC moves.

## 2. RC Highlights

- Release and feature dry-run helpers are worktree-safe, so `release:branch`,
  `release:finalize`, `feature:branch:dry`, and `feature:finalize:dry` behave
  correctly when `develop` is attached elsewhere.
- `priority:pivot:template` now treats `queue-empty` as authoritative and only
  blocks on real remaining gates.
- The downstream proving rail fails closed when template verification is
  missing, stale, or drifted from the pinned template dependency.
- Hosted release readiness now evaluates the live `validate.yml` and
  `fixture-drift.yml` evidence lanes rather than retired self-hosted compare
  workflows.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [ ] Latest `fixture-drift.yml` run for `release/v0.6.4-rc.1` is green and
      uploads the NI Linux review-suite evidence bundle.
- [ ] Latest template verification report stays `pass` for
      `LabviewGitHubCiTemplate@v0.1.1`.
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.4-rc.1` completes
      from a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`.

## 4. Reviewer Focus

- Confirm `CHANGELOG.md`, this helper, `TAG_PREP_CHECKLIST.md`, and
  `../archive/releases/RELEASE_NOTES_v0.6.4-rc.1.md` all reference
  `v0.6.4-rc.1` consistently.
- Review the hosted-first release gate adjustments:
  - `tools/policy/branch-required-checks.json`
  - `tools/priority/lib/release-pr-checks.mjs`
  - `tools/priority/lib/release-compare-evidence.mjs`
- Check that the release branch verification helper is validating real RC
  assets instead of stale historical release docs.
- Check that the fixture-drift hosted Linux lane remains deterministic on
  `release/*` branches while keeping the VI history safeguard honest.

## 5. Follow-Up After RC

1. Cut the final `v0.6.4` release once RC evidence is stable.
2. Re-run the template pivot gate after the RC version is published.
3. Keep the downstream proving rail pinned to the released template tag until a
   deliberate dependency bump is queued.

--- Updated: 2026-03-22 (aligned with the `v0.6.4-rc.1` release candidate).
