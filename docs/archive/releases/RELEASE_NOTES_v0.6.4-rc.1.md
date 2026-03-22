<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4-rc.1

Highlights

- Hosted-first release readiness is now aligned to the real RC gate.
  - `release/*` required checks, promotion-contract expectations, and live
    GitHub rulesets were updated to the same required contexts:
    - `lint`
    - `pester / normalize`
    - `smoke-gate`
    - `Policy Guard (Upstream) / policy-guard`
    - `commit-integrity`
  - Release finalize now uses hosted `validate.yml` and `fixture-drift.yml`
    evidence instead of retired self-hosted compare lanes.
- Release and feature branch helpers are worktree-safe.
  - Detached helper lanes can now run `release:branch:dry`,
    `release:finalize:dry`, `feature:branch:dry`, and
    `feature:finalize:dry` without colliding with other attached `develop`
    worktrees.
  - Bootstrap and develop-sync behavior now degrade safely instead of failing
    when the canonical `develop` worktree is already attached elsewhere.
- The template conveyor remains pinned and part of the proving rail.
  - `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate@v0.1.1` is treated as the
    immutable template dependency for downstream proving.
  - Template verification is refreshed through the cookiecutter conveyor and
    remains part of the release-readiness story.

Upgrade Notes

- This is a release candidate. The final `v0.6.4` release still depends on RC
  validation staying green and the release conductor completing from a clean
  helper lane.
- Hosted release evidence now expects the release branch PR to satisfy the
  aligned required contexts above and to keep the hosted fixture-drift lane
  green with published artifacts.
- The template pivot gate is no longer blocked by queue-state drift. After the
  RC version lands, the remaining pivot blocker should reduce to the final
  release/handoff contract rather than stale standing-issue inventory.

Validation Checklist

- [x] `node --test tools/priority/__tests__/release-pr-checks.test.mjs tools/priority/__tests__/dryrun-helpers.test.mjs`
- [x] `pwsh -NoLogo -NoProfile -File tools/Assert-PromotionContractAlignment.ps1`
- [x] `node tools/npm/run-script.mjs release:branch:dry -- 0.6.4-rc.1`
- [x] `node tools/npm/run-script.mjs release:finalize:dry -- 0.6.4-rc.1`
- [ ] Live hosted RC validation on `release/v0.6.4-rc.1`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.4-rc.1`
