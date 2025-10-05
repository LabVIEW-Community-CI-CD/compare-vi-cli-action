# Workflows Overview

This repository uses a single Windows variant (self-hosted) and gates heavy jobs via a pre‑init check. Below is a concise catalog of all active workflows, their purpose, and key behaviors to help spot drift or candidates for unification.

## Core CI

- CI Orchestrated (deterministic chain)
  - Triggers: manual (`workflow_dispatch`).
  - Jobs: pre‑init → preflight → pester (per‑category, serial) → drift → publish.
  - Gates: skips Windows when docs‑only; single Windows runner; 3‑minute job budgets; per‑category timeouts via `PESTER_TIMEOUT_*`.
- Pester (self‑hosted)
  - Triggers: PR/push to `develop`,`main`; manual.
  - Jobs: pre‑init → preflight → pester (category matrix).
  - Gates/Artifacts: skips on docs‑only; session index + guard; required‑checks summary appended.
- Validate
  - Triggers: PR/push to `main`; manual.
  - Jobs: lint (actionlint, markdownlint, intra‑repo link check) + session index smoke.
  - Summary prints Required Checks block and link to branch rules.

## Drift & Binary Gates

- Fixture Drift Validation
  - Triggers: PR changes to fixtures/scripts/schemas; manual.
  - Jobs: pre‑init → Windows preflight → Windows drift orchestration (Ubuntu leg optional).
  - Uses LVCompare exclusively; session index + guard; optional report.
- VI Binary Handling Gate
  - Triggers: PR/push on `.gitattributes`, scripts, test.
  - Jobs: pre‑init → self‑hosted Windows single‑spec Pester gate.

## Release & Publishing

- Release on tag
  - Triggers: tag push (e.g., `v*`). Publishes release artifacts.
- Compare VI artifact publish
  - Triggers: manual/push (internal publish of compare outputs).
- .NET Shared Library
  - Triggers: push on library paths. Builds and publishes GH Packages.

## Developer Utilities

- Command dispatcher
  - Triggers: `/run …` issue comments. Dispatches CI runs.
- Smoke test (on label / manual)
  - Quick CI wiring checks; no LVCompare popups.
- Pester diagnostics nightly
  - Nightly diagnostic run; candidate for pruning if redundant with self‑hosted matrix.
- Integration Runbook Validation
  - Manual runbook validation.
- Sync Labels
  - Creates/updates repository labels from `.github/labels.yml`.
- markdownlint
  - Dedicated markdown lint runner.

## Composites (reused building blocks)

- `pre-init-gate`: docs‑only detection, fork guidance on failure.
- `pester-category-run`: maps category → test patterns and applies per‑category timeouts.
- `session-index-post`: step summary + schema‑lite validate + artifact upload.
- `runner-unblock-guard`: snapshot and optional cleanup (LabVIEW/LVCompare) with summary.
- `fixture-drift` (composite action): orchestrates drift compare and report.

## Prune/Unify Candidates

- Test (mock LVCompare) – DEPRECATED (kept for manual compatibility only).
- Pester diagnostics nightly – overlap with Pester (self‑hosted) categories; consider consolidation.
- Smoke workflows – keep one variant if usage duplicates.
