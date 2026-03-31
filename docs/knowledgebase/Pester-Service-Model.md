# Pester Service Model

The legacy Pester control plane couples four concerns into one self-hosted transaction:

1. policy routing
2. host-plane readiness
3. test execution
4. evidence generation

That coupling is what makes the monolithic self-hosted seam expensive to reproduce and hard to localize when it stalls or emits `missing-summary`.

## Pilot Split

The additive pilot introduces seven workflow surfaces:

- `.github/workflows/pester-context.yml`
  - repo/control-plane receipts for repository slug, token-backed standing-priority sync, and context classification
- `.github/workflows/pester-gate.yml`
  - top-level router for the pilot service model
- `.github/workflows/pester-service-model-on-label.yml`
  - trusted PR/dispatch entrypoint for proving the pilot without exposing the self-hosted ingress plane to untrusted fork heads
- `.github/workflows/selfhosted-readiness.yml`
  - host-plane readiness receipts for the self-hosted ingress surface
- `.github/workflows/pester-selection.yml`
  - receipt-driven pack shaping for integration mode, include patterns, and dispatcher profile resolution
- `.github/workflows/pester-run.yml`
  - receipt-driven Pester execution only
- `.github/workflows/pester-evidence.yml`
  - summary, classification, session-index, dashboard, and artifact publication
- `tools/Run-PesterExecutionOnly.Local.ps1`
  - local harness for the execution slice without the workflow shell: lock, LV guard,
    fixture prep, dispatcher profile, dispatch, execution postprocess, and local execution receipt
- `tools/Invoke-PesterExecutionPostprocess.ps1`
  - execution-post contract for XML integrity classification and machine-readable summary repair

## Design Rules

- Context certifies repo/control-plane assumptions. It does not probe host readiness or execute tests.
- Selection resolves integration mode, include patterns, and dispatcher profile into a receipt before execution begins.
- Selection consumes context. It does not probe host readiness or invoke the dispatcher.
- Readiness certifies the environment. It does not execute the test pack.
- Readiness consumes context. It does not discover standing-priority state itself.
- Readiness emits a bounded-freshness receipt artifact that execution must download and validate before dispatch.
- Execution consumes context, selection, and readiness. It does not normalize pack inputs, choose the dispatcher profile, bootstrap Docker runtimes, install core toolchains, or discover standing-priority state.
- Execution writes an execution receipt before uploading raw artifacts so evidence can classify the real seam outcome.
- Execution must also emit a skip-safe execution contract from an always-on finalize path so reusable-workflow outputs do not collapse when the execution job never starts.
- Execution-post shall classify `results-xml-truncated`, `invalid-results-xml`, and `missing-results-xml` explicitly instead of collapsing XML integrity debt into generic `seam-defect`.
- Local iteration must not depend on the workflow shell. The local harness should
  make the execution slice runnable on its own while keeping the same preflight
  and receipt boundaries.
- Evidence consumes raw execution output plus the execution receipt. It classifies `context-blocked`, `readiness-blocked`, and `seam-defect` explicitly instead of collapsing them into one execution symptom.
- The existing required gate remains in place until the pilot proves equivalent or better behavior.
- Trusted PR proving must stay on `pull_request_target` with same-owner gating. Cross-owner fork heads are not allowed to drive self-hosted execution.

## Promotion Rule

The pilot can replace the monolith only after:

- readiness receipts are stable on the ingress host
- selection receipts resolve the declared pack and dispatcher profile without execution-side drift
- execution runs the declared pack without host bootstrap
- evidence produces deterministic classifications
- PR/release comparisons show better failure localization and lower operator ambiguity

## Promotion Packet

The current upstream promotion packet for the pilot is hosted-first:

- `docs/requirements-pester-service-model-srs.md`
- `docs/rtm-pester-service-model.csv`
- `.github/workflows/pester-service-model-quality.yml`
- `.github/workflows/pester-service-model-release-evidence.yml`

That packet is derived from the retained fork dossier on `#2078` and is used to
justify the next minimal upstream slice on `#2069`.
