<!-- markdownlint-disable-next-line MD041 -->
# Hosted Signal Report-First Contract

This contract applies to hosted workflows whose primary job is to evaluate, summarize, or enforce repository state
rather than build product artifacts.

## When to use this pattern

Use the `report-first` pattern when a hosted workflow exists to:

- evaluate GitHub or repository policy state
- summarize health, onboarding, hygiene, or governance signals
- emit machine-readable evidence for future-agent triage

Do not use this pattern for build/product workflows that cannot produce a meaningful report before runtime setup
completes.

## Required workflow behavior

Hosted signal workflows that follow this contract must:

1. export both `GH_TOKEN` and `GITHUB_TOKEN`
2. write a machine-readable report or failure envelope whenever runtime setup can still explain the failure
3. gate schema validation and artifact uploads on report existence so secondary missing-file cascades do not hide the
   primary failure
4. preserve one explicit enforcement step that fails the job on the actual signal failure condition
5. append a deterministic step summary from the emitted report when present

## Canonical examples

- `.github/workflows/issue-milestone-hygiene.yml`
- `.github/workflows/downstream-onboarding-feedback.yml`

## Workflow shape

The expected pattern is:

1. export the token surface in workflow env
2. run the evaluation harness with `continue-on-error` only when a later explicit enforcement step will own failure
3. validate only the report files that exist
4. upload only the artifacts that exist
5. append a summary from the report
6. fail once, in the final enforcement step, if the underlying signal is unhealthy

## Future-agent guidance

When adding a new hosted signal workflow:

- start from one of the canonical examples above
- keep report schemas workflow-specific when needed
- keep the `report-first` envelope and existence-aware follow-on behavior consistent with this contract
- prefer one clear failure over multiple secondary upload/schema failures
