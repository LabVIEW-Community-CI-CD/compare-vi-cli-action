<!-- markdownlint-disable-next-line MD041 -->
# Maintainer Continuity Profile

This repository currently has a single checked-in codeowner route:

- [`.github/CODEOWNERS`](../.github/CODEOWNERS) => `@svelderrainruiz`

That is an honest continuity constraint, not a defect to hide. The repository
has substantial automation and runbook coverage, but it does not currently have
true reviewer or operator redundancy.

## What is true today

- Product and workflow ownership are concentrated in one human maintainer.
- Release and governance workflows are heavily automated and documented.
- Continuity depends on checked-in contracts, tagged artifacts, and repeatable
  runbooks more than on institutional headcount.

## Current continuity controls

These controls reduce memory risk and improve recoverability even though they do
not create separation of duties by themselves:

- [`WORKFLOW_CRITICALITY_MAP.md`](./WORKFLOW_CRITICALITY_MAP.md)
  Classifies which workflow edits affect release, product validation, platform
  governance, or diagnostics.
- [`RELEASE_OPERATIONS_RUNBOOK.md`](./RELEASE_OPERATIONS_RUNBOOK.md)
  Defines the release, approval, escalation, and rollback operating model.
- [`MINIMAL_ADOPTER_CONTRACT.md`](./MINIMAL_ADOPTER_CONTRACT.md)
  Keeps downstream adoption expectations narrow and explicit.
- [`SUPPORTED_PRODUCT_BOUNDARY.md`](./SUPPORTED_PRODUCT_BOUNDARY.md)
  Separates the public supported surface from maintainer/operator internals.
- `.github/workflows/release-conductor.yml`,
  `.github/workflows/release.yml`, and
  `.github/workflows/release-rollback-drill.yml`
  Provide authoritative release, repair, and rollback paths.
- `.github/workflows/policy-guard-upstream.yml`,
  `.github/workflows/commit-integrity.yml`, and
  `.github/workflows/weekly-scorecard.yml`
  Continuously surface policy drift, history risk, and governance regressions.

## What this profile does not claim

- It does not claim multi-maintainer review depth.
- It does not claim separation of duties for release approval.
- It does not claim 24/7 human coverage.
- It does not claim that automation alone substitutes for a second maintainer.

## How to read the repository

For external consumers, the right trust posture is:

- trust the supported product boundary and tagged release evidence
- trust the runbooks and release workflows as continuity controls
- do not assume that every maintainer/operator workflow implies staffed
  redundancy

For maintainers, the right operating posture is:

- avoid implying multi-operator governance where it does not exist
- keep critical paths documented and reproducible
- prefer release/runbook changes that reduce recovery friction for a future
  second maintainer

## Hardening priorities

1. Add at least one additional human maintainer and extend `CODEOWNERS`
   accordingly.
2. Split release-approval and incident-command responsibilities across more than
   one person when the team exists.
3. Keep release, rollback, and governance evidence attached to issues/PRs so a
   future maintainer can reconstruct state without private context.
