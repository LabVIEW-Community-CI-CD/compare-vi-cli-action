# Release Review Platform Plan

This plan governs the fork implementation track for release-time, multi-OS, multi-scenario VI History review.

## Standing Priority Issue

- Active standing issue (fork): #216
- Issue URL: https://github.com/svelderrainruiz/compare-vi-cli-action/issues/216
- Rule: this roadmap and issue #216 must stay in sync whenever phase status changes.

## Objective

Turn release validation into a structured review platform where every tag produces:

- independent Windows and Linux review evidence,
- multiple scenario reports per OS,
- policy-driven quality decisions,
- reviewer-facing summary artifacts,
- trendable historical outputs.

## Scope

In scope:

- release workflow orchestration,
- scenario execution contracts,
- artifact publishing/indexing,
- policy gating,
- reviewer communication surfaces,
- analytics-ready summary outputs.

Out of scope (for this track):

- replacing existing CLI release assets,
- changing branch protection policy outside mapped check contracts,
- removing existing validation lanes before migration is complete.

## Delivery Phases

## Issue-Linked Phase Checklist

Use this section as the canonical phase checklist mirrored in issue #216.

- [ ] Phase 1 — Contracts and Foundations
- [x] Phase 2 — Scenario Strategy as Data
- [x] Phase 3 — Evidence Producers (OS × Scenario)
- [x] Phase 4 — Review Index and Reviewer UX
- [x] Phase 5 — Policy Gate and Promotion Controls
- [x] Phase 6 — Unified Comment Publishing
- [x] Phase 7 — Historical Analytics
- [ ] Phase 8 — Hardening and Migration (started)

## Phase 1 — Contracts and Foundations

Goal: define a single review data contract and validate it in CI.

Deliverables:

- canonical review schema(s) for OS/scenario summary payloads,
- validation hooks in CI/pre-push,
- contract documentation with field definitions.

Exit criteria:

- schema validation runs green in fork,
- all new release review outputs conform to schema,
- no drift with current required check naming contracts.

## Phase 2 — Scenario Strategy as Data

Goal: move scenario selection from script-only behavior to manifest/policy-first config.

Deliverables:

- manifest-backed release review profiles (for example: smoke, history-core, full),
- explicit scenario ID mapping and per-scenario flags,
- backward-compatible defaults.

Exit criteria:

- release workflow can select profile deterministically,
- scenario fan-out is reproducible across reruns,
- profile changes require only data updates for common cases.

## Phase 3 — Evidence Producers (OS × Scenario)

Goal: produce independent review artifacts for each OS/scenario lane.

Deliverables:

- release matrix jobs producing per-lane artifacts,
- lane summaries including compare exit, gate outcome, result class, status,
- stable artifact naming strategy for reviewer retrieval.

Exit criteria:

- Windows and Linux lanes each publish all configured scenario artifacts,
- hard failures still stop release validation correctly,
- expected diff outcomes are preserved as reviewable evidence.

## Phase 4 — Review Index and Reviewer UX

Goal: provide one review index and clear links for manual decision-making.

Deliverables:

- aggregated markdown + JSON review index artifact,
- step summary table with OS/scenario status rows,
- reviewer-oriented grouping (baseline/noattr/layout-position).

Exit criteria:

- reviewer can locate all lane artifacts in <2 minutes,
- index includes explicit pass/warn/fail signal per lane,
- release run summary is readable without opening raw logs.

## Phase 5 — Policy Gate and Promotion Controls

Goal: turn review evidence into policy-enforced release decisions.

Deliverables:

- policy file(s) declaring required scenarios and acceptable result classes,
- evaluation step producing pass/warn/fail,
- promotion behavior controls (RC strictness, latest tagging safeguards).

Exit criteria:

- policy evaluation is deterministic and auditable,
- failure causes are actionable and lane-specific,
- check naming remains aligned with branch protection contracts.

## Phase 6 — Unified Comment Publishing

Goal: standardize stakeholder updates for PR/release/issue channels.

Deliverables:

- reusable rendering/publishing utility,
- standardized body format with truncation safeguards,
- consistent inclusion of run links and artifact references.

Exit criteria:

- review comments are stable across workflows,
- output format is consistent and machine-auditable,
- no duplicated comment logic with divergent behavior.

## Phase 7 — Historical Analytics

Goal: track quality trends across releases.

Deliverables:

- normalized historical summary artifacts per release,
- aggregate trend report (OS/scenario regressions, recurrence patterns),
- baseline metrics for release review health.

Exit criteria:

- trend report can answer: what regressed, how often, on which OS/scenario,
- artifacts are usable without external database dependencies,
- migration path is defined for deeper telemetry/session-index integration.

## Phase 8 — Hardening and Migration

Goal: enforce stable operations and retire legacy duplication safely.

Deliverables:

- backward compatibility adapters for older outputs,
- rollout gates (observe → soft gate → hard gate),
- runbook updates and incident playbook.

Exit criteria:

- no critical release regressions during migration,
- legacy outputs retired only after parity and stakeholder sign-off,
- deterministic reruns and clear rollback steps.

## Decision Gates

- Gate A (after Phase 2): scenario model accepted by reviewers.
- Gate B (after Phase 4): review UX is considered sufficient for manual sign-off.
- Gate C (after Phase 5): policy gate enabled for target tag classes.
- Gate D (after Phase 7): trend outputs used in at least one release decision cycle.

## Operating Rules

- Keep release assets additive; do not disrupt existing CLI asset publishing.
- Maintain required-check name compatibility with policy contracts.
- Preserve deterministic runtime controls and known runner constraints.
- Prefer policy/data files over embedded workflow condition complexity.

## Immediate Backlog (Fork)

1. Add compatibility normalization adapter for legacy scenario summary aliases.
2. Add migration rollout config (`observe`/`soft`/`hard`) with schema validation.
3. Validate migration controls in release and pre-push checks.
4. Continue monitoring stable-tag hard enforcement across subsequent release cycles.

## Progress Tracker

- [x] Release-time OS/scenario artifact fan-out (initial implementation)
- [x] Release review index artifact + step summary (initial implementation)
- [x] Canonical review schema + CI contract checks
- [x] Scenario profile manifest + selector
- [x] Policy gate enforcement
- [x] Unified comment publishing
- [x] Historical trend aggregation
- [x] Phase 8 kickoff: compatibility adapter + migration rollout mode scaffold
- [x] Phase 8 slice: tag-class soft-gate adoption (RC soft, stable hard)
- [x] Phase 8 slice: migration runbook + incident/rollback playbook
- [x] Phase 8 slice: rollback verification proof run completed
- [x] Phase 8 slice: stable-enforcement monitoring tracker template
- [x] Phase 8 slice: policy-field extraction helper automation
- [ ] Migration hardening and rollout controls

## References

- release workflow: `.github/workflows/release.yml`
- validate workflow: `.github/workflows/validate.yml`
- scenario harness: `fixtures/vi-history/pr-harness.json`
- policy contracts: `tools/policy/branch-required-checks.json`
- session index schema: `docs/schemas/session-index-v1.schema.json`
- release review contract: `docs/RELEASE_VI_HISTORY_REVIEW_CONTRACT.md`
- release profile manifest: `docs/RELEASE_VI_HISTORY_PROFILE_MANIFEST.md`
- release policy gate: `docs/RELEASE_VI_HISTORY_POLICY_GATE.md`
- release comment publishing: `docs/RELEASE_VI_HISTORY_COMMENT_PUBLISHING.md`
- release trends: `docs/RELEASE_VI_HISTORY_TRENDS.md`
- release migration hardening: `docs/RELEASE_VI_HISTORY_MIGRATION_HARDENING.md`
- release migration runbook: `docs/RELEASE_VI_HISTORY_MIGRATION_RUNBOOK.md`
- release migration incident playbook: `docs/RELEASE_VI_HISTORY_MIGRATION_INCIDENT_PLAYBOOK.md`
- stable enforcement monitoring: `docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md`
- policy field helper: `tools/Get-ReleaseVIHistoryPolicyFields.ps1`
