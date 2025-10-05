# CI Pipeline Depth (Draft)

This document outlines the current gating layers and job topology used across the repo. It helps humans visualize how checks compose and where to refine next. Treat this as a living systems map.

## Legend

- Gate: hard/soft precondition that must pass before proceeding
- Job: CI unit of work (GitHub Actions job)
- Step: action within a job

## Global Toggles & Inputs

- Branch protection gate toggles (default ON)
  - `ENFORCE_PROTECTION_ON_DEVELOP=0` → disable gate on `develop` (unset treated as ON)
  - `ENFORCE_PROTECTION_ON_TOPIC=0` → disable gate on topic branches (`feature/*`, `bugfix/*`, `hotfix/*`, `chore/*`)
- Admin token sources (in order)
  - File (self-hosted): `C:\actions-runner\GH_ADMIN_TOKEN.txt`
  - Secret: `GH_ADMIN_TOKEN`
  - Fallback (limited): `GITHUB_TOKEN`

## Validate (main/release/* always; develop/topic via toggles)

```text
[protect: Branch Protection Gate]
  ├─ reads required checks (API) or Rulesets fallback
  ├─ strict fail on missing checks
  └─ detailed notice when no access (with links)
       ↓
[lint]
  ├─ actionlint
  ├─ markdownlint
  ├─ PR template linter (sections + required checklist)
  ├─ Labels sync summary (config vs live)
  │    └─ fails on main when Missing ≠ 0
  └─ Repo hygiene (warn; strict on main/release/*)
       ↓
[fixtures (Windows)] (non-blocking summary)
```text

## Pester (self-hosted)

```text
[protect: Branch Protection Gate (PR base)]
       ↓
[pre-init]
  ├─ pre-init gate (docs-only fast path)
  └─ bool-normalize include_integration
       ↓
[preflight (Windows)]
  └─ verify LVCompare; ensure LabVIEW not running
       ↓
[pester (Windows)] matrix per category
  ├─ dispatcher | fixtures | schema | comparevi | loop | runbook | orchestrator
  ├─ session-index-post (summary + schema-lite + artifact)
  └─ runner-unblock-guard (snapshot + optional cleanup)
```text

## CI Orchestrated (deterministic chain)

```text
[protect: Branch Protection Gate (PR base)]
       ↓
[pre-init]
  └─ as above
       ↓
[preflight (Windows)]
       ↓
[pester (Windows) per category]
       ↓
[drift (Windows)]
  ├─ fixture drift orchestrator
  ├─ report (execJson preferred; Source shown)
  └─ runner-unblock-guard
       ↓
[publish]
  └─ summary of lint/pester/drift
```

## Label-Driven Execution

- `smoke` (PR label) → smoke.yml (Windows)
  - Validates fixtures; runs local action; posts PR comment using admin token bootstrap (file → secret → GITHUB_TOKEN)
- `test-integration` (PR label) → pester-integration-on-label.yml (Windows)
  - Installs Pester; runs integration tests; posts PR comment using admin token (secret → GITHUB_TOKEN)

## Gates Stack (Conceptual)

1. Admin Token Bootstrap (self-hosted only)
2. Branch Protection Gate (fail-fast; rulesets fallback)
3. Labels Sync Summary (drift surfaces in Validate; fails on main)
4. PR Template Linter (structure + required checklists)
5. Pre-Init Gate (docs-only fast path)
6. Windows Preflight (CLI available; LabVIEW closed)
7. Pester Matrix → Session Index → Guard
8. Drift Orchestrator (optional report) → Guard

## Refinement Ideas

- Enforce labels palette drift on `develop` after a soak period
- Branch-specific rules pages for `release/x` series (temporary deviations + sunset date)
- Optional strict mode for drift report source (execJson required)
- Gate exceptions (e.g., docs-only) enumerated per branch in `docs/branch-rules/<branch>.md`	ext

