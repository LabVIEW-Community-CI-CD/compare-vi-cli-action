# Branch Rules and Required Checks

This repository uses a single Windows variant (self‑hosted) and deterministic gates to keep CI fast and predictable. Use these rules as your source of truth when configuring branch protections or forking the project.

## Branch Policies

- main
  - Merge queue required; squash only; auto‑delete branches.
  - Reviews: 2 approvals (CODEOWNERS required); dismiss stale reviews; conversations resolved.
  - Required checks:
    - Pester (self-hosted) / preflight
    - Pester (self-hosted) / pester (dispatcher|fixtures|schema|comparevi|loop|runbook|orchestrator)
    - Fixture Drift Validation / Fixture Drift (Windows)
    - VI Binary Handling Gate / vi-binary-check
    - Validate / lint
    - markdownlint / lint
- develop (default)
  - Merge queue required; squash; auto‑delete.
  - Reviews: 1 approval.
  - Required checks (recommended): same as main. Docs‑only PRs skip Windows via pre‑init gate.
- release/* and release/*‑rc.*
  - Merge queue; 2 approvals.
  - Required checks: same as main.
- feature/*, bugfix/*, chore/*, hotfix/*
  - No direct protections (target develop). Quality enforced by target branch rules.

## Determinism & Gates

- Windows runner labels: `[self-hosted, Windows, X64]` (no `windows‑20xx`).
- Pre‑init gate (docs‑only fast path):
  - Skips heavy Windows jobs when changes are only in `docs/**` or `**/*.md`.
  - Exception: `docs/schemas/**` still runs Windows jobs.
  - Forks: pre‑init provides guidance and can be configured to fail early.
- Job budgets: 3 minutes per job; category timeouts tunable via repo Variables:
  - `PESTER_TIMEOUT_DISPATCHER`, `PESTER_TIMEOUT_FIXTURES`, `PESTER_TIMEOUT_SCHEMA`,
    `PESTER_TIMEOUT_COMPAREVI`, `PESTER_TIMEOUT_LOOP`, `PESTER_TIMEOUT_RUNBOOK`,
    `PESTER_TIMEOUT_ORCHESTRATOR`.
- Boolean normalization: workflows use `./.github/actions/bool-normalize` for stable true/false parsing.

## Forks

- Set repo Variable `EXPECTED_REPO_OWNER` to your owner to tailor pre‑init fork guidance.
- Mirror required checks above on your protected branches for consistent signals.

## Hygiene

- Validate workflow runs a repo hygiene check; it fails on `main` and `release/*` if unexpected top‑level files/dirs are present.
- Keep samples under `docs/samples/` and planning notes under `docs/releases/`.

## Protection Gate (CI)

- The Validate and self‑hosted Pester workflows include a Branch Protection Gate that checks required status checks on the target branch before running.
- When missing checks are detected, CI fails fast with a summary of what’s missing.
- If no admin PAT is available (secret `XCLI_PAT`), the gate writes a notice‑only summary with:
  - Expected checks
  - Links to this doc in the PR head fork (`docs/BRANCH_RULES.md`)
  - The repository Branch protection settings page
  - Steps to enforce (add `XCLI_PAT`, configure checks, re‑run)
- Develop toggle: set repo variable `ENFORCE_PROTECTION_ON_DEVELOP=1` to enforce this gate on `develop` as well (default is off).
