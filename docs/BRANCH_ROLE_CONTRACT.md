<!-- markdownlint-disable-next-line MD041 -->
# Branch Role Contract

This document defines the branch classes, repository planes, and allowed transitions that unattended delivery, sync
helpers, hook orchestration, and branch-protection documentation must share.

## Purpose

The repository no longer treats every branch named `develop`, `main`, or `issue/*` as if it served the same role.
Instead, branch behavior is driven by one machine-readable contract:

- policy artifact: [tools/policy/branch-classes.json](../tools/policy/branch-classes.json)
- schema: [docs/schemas/branch-classes-v1.schema.json](schemas/branch-classes-v1.schema.json)

This contract now makes the three collaboration planes explicit:

- `upstream` = daemon and promotion authority
- `origin` = org-fork review plane
- `personal` = personal authoring plane

## Repository Planes

| Plane | Repository | `develop` semantics | Lane prefix | Personas | Purpose |
| --- | --- | --- | --- | --- | --- |
| `upstream` | `LabVIEW-Community-CI-CD/compare-vi-cli-action` | canonical integration branch (`upstream-integration`) | `issue/` | `daemon` | Queue-managed integration and promotion surface |
| `origin` | `LabVIEW-Community-CI-CD/compare-vi-cli-action-fork` | mirror-only fork `develop` (`fork-mirror-develop`) | `issue/origin-` | `copilot-cli` | Org-fork review plane before upstream promotion |
| `personal` | `svelderrainruiz/compare-vi-cli-action` | mirror-only fork `develop` (`fork-mirror-develop`) | `issue/personal-` | `codex`, `codex-cli` | Personal authoring plane before review or upstream promotion |

## Branch Classes

| Class | Repository role | Pattern | Purpose | Promotion contract |
| --- | --- | --- | --- | --- |
| `upstream-integration` | upstream | `develop` | Canonical integration branch | Queue-managed squash only |
| `upstream-release` | upstream | `main` | Protected release branch | Queue-managed squash only |
| `upstream-release-prep` | upstream | `release/*` | Release-preparation branches | Rebase-only PR promotion |
| `downstream-consumer-proving-rail` | upstream | `downstream/develop` | Consumer proving rail fed from immutable upstream manifests | Promotion-manifest only |
| `fork-mirror-develop` | fork | `develop` | Mirror/sync copy of upstream `develop` | Mirror-only, never an implementation or PR source surface |
| `fork-passive-main` | fork | `main` | Optional passive mirror of upstream `main` | Mirror-only |
| `lane` | upstream or fork | `issue/*` | Short-lived implementation branches | PR source only |
| `feature` | upstream or fork | `feature/*` | Explicit rehearsal/experiment branches | PR source only |
| `merge-queue` | upstream | `gh-readonly-queue/**` | GitHub-owned merge queue refs | Queue-owned; never human or agent writable |

## Class Transitions

The `Via` column below mirrors the exact `allowedTransitions[*].via` tokens from
[tools/policy/branch-classes.json](../tools/policy/branch-classes.json).

| From | Action | To | Via |
| --- | --- | --- | --- |
| `lane` | `promote` | `upstream-integration` | `pull-request` |
| `feature` | `promote` | `upstream-integration` | `pull-request` |
| `lane` | `promote` | `upstream-release-prep` | `pull-request` |
| `upstream-release-prep` | `promote` | `upstream-release` | `pull-request` |
| `upstream-integration` | `promote` | `downstream-consumer-proving-rail` | `downstream-promotion-manifest` |
| `upstream-integration` | `sync` | `fork-mirror-develop` | `priority:develop:sync` |
| `upstream-integration` | `queue` | `merge-queue` | `priority:merge-sync` |
| `upstream-release` | `queue` | `merge-queue` | `priority:merge-sync` |
| `merge-queue` | `merge` | `upstream-integration` | `github-merge-queue` |
| `merge-queue` | `merge` | `upstream-release` | `github-merge-queue` |
| `upstream-integration` | `branch` | `lane` | `issue/*` |
| `upstream-integration` | `branch` | `feature` | `feature/*` |
| `fork-mirror-develop` | `branch` | `lane` | `issue/*` |

## Plane Transitions

The explicit collaboration flow between forks now lives beside the generic branch classes.

| From plane | Action | To plane | Via | Branch class |
| --- | --- | --- | --- | --- |
| `upstream` | `sync` | `origin` | `priority:develop:sync` | `fork-mirror-develop` |
| `upstream` | `sync` | `personal` | `priority:develop:sync` | `fork-mirror-develop` |
| `personal` | `review` | `origin` | `pull-request` | `lane` |
| `personal` | `promote` | `upstream` | `pull-request` | `lane` |
| `origin` | `promote` | `upstream` | `pull-request` | `lane` |

## Operational Implications

- `upstream/develop` is the only integration surface for standing work.
- `downstream/develop` is a proving rail, not a feature branch. It should only be updated from immutable promotion manifests sourced from `upstream/develop`.
- `origin/develop` and `personal/develop` are mirrors, not independent integration branches.
- The personal plane is optimized for authoring; the org fork is optimized for review-oriented collaboration.
- Lane branches may exist in forks, but they still promote into upstream protected branches.
- Merge queue refs are their own branch class, not a special case of `develop` or `main`.
- The branch prefix itself should reveal the active plane:
  - `issue/personal-*` for the personal authoring plane
  - `issue/origin-*` for the org-fork review plane
  - bare `issue/*` for upstream-native lanes

## Helper Consumption

The contract is consumed directly by:

- `priority:develop:sync`, which validates the upstream `develop` -> fork `develop` mirror transition
- `priority:policy`, which applies the checked-in fork `develop` override so mirror rails keep `allow_force_pushes=true` and `allow_fork_syncing=false` instead of drifting back toward upstream integration settings
- `priority:merge-sync`, which classifies the target base branch before choosing queue-aware promotion behavior
- `tools/priority/lib/branch-classification.mjs`, which now resolves both repository role and explicit repository plane

Future work under epic `#1086` should migrate other branch-role assumptions onto the same contract instead of creating
parallel policy files.
