<!-- markdownlint-disable-next-line MD041 -->
# Branch Role Contract

This document defines the branch classes and allowed transitions that unattended delivery, sync helpers, and
branch-protection documentation must share.

## Purpose

The repository no longer treats every branch named `develop`, `main`, or `issue/*` as if it served the same role.
Instead, branch behavior is driven by one machine-readable contract:

- policy artifact: [tools/policy/branch-classes.json](../tools/policy/branch-classes.json)
- schema: [docs/schemas/branch-classes-v1.schema.json](schemas/branch-classes-v1.schema.json)

## Branch Classes

| Class | Repository role | Pattern | Purpose | Promotion contract |
| --- | --- | --- | --- | --- |
| `upstream-integration` | upstream | `develop` | Canonical integration branch | Queue-managed squash only |
| `upstream-release` | upstream | `main` | Protected release branch | Queue-managed squash only |
| `upstream-release-prep` | upstream | `release/*` | Release-preparation branches | Rebase-only PR promotion |
| `fork-mirror-develop` | fork | `develop` | Mirror/sync copy of upstream `develop` | Mirror-only, never an implementation or PR source surface |
| `fork-passive-main` | fork | `main` | Optional passive mirror of upstream `main` | Mirror-only |
| `lane` | upstream or fork | `issue/*` | Short-lived implementation branches | PR source only |
| `feature` | upstream or fork | `feature/*` | Explicit rehearsal/experiment branches | PR source only |
| `merge-queue` | upstream | `gh-readonly-queue/*` | GitHub-owned merge queue refs | Queue-owned; never human or agent writable |

## Allowed Transitions

| From | Action | To | Via |
| --- | --- | --- | --- |
| `lane` | `promote` | `upstream-integration` | PR merge into `develop` |
| `feature` | `promote` | `upstream-integration` | PR merge into `develop` |
| `lane` | `promote` | `upstream-release-prep` | Release PR |
| `upstream-release-prep` | `promote` | `upstream-release` | Release PR |
| `upstream-integration` | `sync` | `fork-mirror-develop` | `priority:develop:sync` |
| `upstream-integration` | `queue` | `merge-queue` | `priority:merge-sync` |
| `upstream-release` | `queue` | `merge-queue` | `priority:merge-sync` |
| `merge-queue` | `merge` | `upstream-integration` | GitHub merge queue |
| `merge-queue` | `merge` | `upstream-release` | GitHub merge queue |
| `upstream-integration` | `branch` | `lane` | `issue/*` |
| `upstream-integration` | `branch` | `feature` | `feature/*` |
| `fork-mirror-develop` | `branch` | `lane` | fork lane creation only; promotion still targets upstream |

## Operational Implications

- `upstream/develop` is the only integration surface for standing work.
- `origin/develop` and other fork `develop` branches are mirrors, not independent integration branches.
- Lane branches may exist in forks, but they still promote into upstream protected branches.
- Merge queue refs are their own branch class, not a special case of `develop` or `main`.

## Helper Consumption

The contract is consumed directly by:

- `priority:develop:sync`, which validates the upstream `develop` -> fork `develop` mirror transition
- `priority:merge-sync`, which classifies the target base branch before choosing queue-aware promotion behavior

Future work under epic `#1038` should migrate other branch-role assumptions onto the same contract instead of creating
parallel policy files.
