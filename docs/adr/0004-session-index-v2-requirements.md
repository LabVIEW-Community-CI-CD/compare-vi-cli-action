---
adr: 0004
title: Session Index v2 Requirements for Local CI
status: proposed
date: 2025-10-11
decision-makers:
  - compare-vi-cli agent team
related-issues:
  - "#118"
requirements:
  - id: session-index.v2.branchProtection.expected
    description: Record the canonical branch-protection contexts for the evaluated branch.
    path: branchProtection.expected
    rule: nonEmptyArray
    severity: error
  - id: session-index.v2.branchProtection.produced
    description: Record the produced contexts emitted by the workflow for comparison.
    path: branchProtection.produced
    rule: nonEmptyArray
    severity: warning
  - id: session-index.v2.tests.summary
    description: Provide aggregate test totals for dashboards and summaries.
    path: tests.summary
    rule: required
    severity: error
  - id: session-index.v2.tests.cases
    description: Surface detailed per-test telemetry for dashboards and traceability.
    path: tests.cases
    rule: nonEmptyArray
    severity: error
  - id: session-index.v2.tests.cases.outcome
    description: Ensure each recorded test case has an explicit outcome value.
    path: tests.cases
    rule: everyCaseHas
    field: outcome
    severity: error
  - id: session-index.v2.tests.cases.requirement
    description: Encourage linking tests to requirements when information is available.
    path: tests.cases
    rule: everyCaseHas
    field: requirement
    severity: warning
---

# ADR 0004 – Session Index v2 Requirements for Local CI

## Status

Proposed – open for feedback as we finish migrating dashboards and local tooling to session-index v2.

## Context

- Session-index v1 was sufficient for simple dashboards but lacked branch-protection and per-test metadata.
- Our TypeScript builder and workflows now emit `session-index.v2.json` containing branch protection, per-test details, and richer run context.
- We want local CI (developers running scripts from VS Code or the command line) to enforce a baseline set of fields so dashboards and automation stay healthy.

## Decision

- Normalize the requirements for session-index v2 in a single machine-readable location (this ADR front matter).
- Provide a TypeScript helper that parses these requirements and validates `session-index.v2.json`.
- Wire the validation into `tools/Write-SessionIndexV2.ps1` so the local/CI flow fails fast when required data is missing.

## Consequences

- Developers get immediate feedback when metadata is missing, preventing drift between local runs and CI dashboards.
- Dashboards can rely on per-test cases and branch-protection data without needing defensive fallbacks.
- Documentation and enforcement stay in sync: updating the ADR updates the validation rules.

Future work: extend the requirement set as we add additional metadata (e.g., traceability IDs, expected results, rationale) and consider generating the schema documentation from the same source.
