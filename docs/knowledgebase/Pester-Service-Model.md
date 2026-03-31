# Pester Service Model

The legacy Pester control plane couples four concerns into one self-hosted transaction:

1. policy routing
2. host-plane readiness
3. test execution
4. evidence generation

That coupling is what makes the monolithic self-hosted seam expensive to reproduce and hard to localize when it stalls or emits `missing-summary`.

## Pilot Split

The additive pilot introduces four workflow surfaces:

- `.github/workflows/pester-gate.yml`
  - top-level router for the pilot service model
- `.github/workflows/selfhosted-readiness.yml`
  - host-plane readiness receipts for the self-hosted ingress surface
- `.github/workflows/pester-run.yml`
  - receipt-driven Pester execution only
- `.github/workflows/pester-evidence.yml`
  - summary, classification, session-index, dashboard, and artifact publication

## Design Rules

- Readiness certifies the environment. It does not execute the test pack.
- Execution consumes readiness. It does not bootstrap Docker runtimes or install core toolchains.
- Evidence consumes raw execution output. It classifies `seam-defect` explicitly when execution never yields a valid summary.
- The existing required gate remains in place until the pilot proves equivalent or better behavior.

## Promotion Rule

The pilot can replace the monolith only after:

- readiness receipts are stable on the ingress host
- execution runs the declared pack without host bootstrap
- evidence produces deterministic classifications
- PR/release comparisons show better failure localization and lower operator ambiguity

