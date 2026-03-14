<!-- markdownlint-disable-next-line MD041 -->
# Public Linux Diagnostics Assisted Runbook

This runbook defines the assisted multi-run session flow for the public Linux diagnostics harness tracked under epic
`#958`.

Use it when an operator and an agent need to repeat local and hosted diagnostics runs against a public repository and a
branch or ref derived from `develop`.

## Preconditions

- Target repository is public.
- Target branch/ref is derived from `develop` and is either equal to or ahead of it.
- The shared contract remains authoritative:
  - `docs/PUBLIC_LINUX_DIAGNOSTICS_HARNESS_CONTRACT.md`
  - `docs/schemas/public-linux-diagnostics-harness-contract-v1.schema.json`

## Assisted Session Loop

1. Confirm the target repository, reference, and `developRelationship`.
2. Run the local entry point when the operator wants a local Docker/Desktop pass first:
   - `tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite`
3. Use the hosted manual workflow when the operator wants a GitHub-backed run:
   - `.github/workflows/public-linux-diagnostics-harness.yml`
4. Inspect the deterministic dispatch receipt:
   - `tests/results/_agent/diagnostics/public-linux-diagnostics-workflow-dispatch.json`
5. Inspect the diagnostics bundle in this order:
   - `tests/results/docker-tools-parity/review-loop-receipt.json`
   - `tests/results/_agent/verification/docker-review-loop-summary.json`
   - `tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-report/results/history-summary.json`
   - `tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-report/results/history-report.html`
6. When the consolidated renderer is available on the current branch, prefer:
   - `tools/priority/public-linux-diagnostics-review-summary.mjs`
   - `tests/results/_agent/diagnostics/public-linux-diagnostics-review-summary.json`
   - `tests/results/_agent/diagnostics/public-linux-diagnostics-review-summary.md`
7. Record the final human disposition through:
   - `.github/workflows/human-go-no-go-feedback.yml`
   - `tests/results/_agent/handoff/human-go-no-go-decision.json`

## Multi-Run Guidance

- Keep every run scoped to one public repository and one reference.
- Do not overwrite the operator’s conclusion from a prior run; each final disposition belongs to the recorded decision
  artifact for that run.
- Treat the hosted workflow dispatch receipt and the local review bundle as review inputs, not as automatic approval.
- If the target reference changes, restart the loop and produce a new receipt set.
- If the diagnostics bundle is incomplete or corrupt, fail closed and rerun rather than improvising missing evidence.

## Operator / Agent Split

- The agent may:
  - prepare inputs
  - run the local harness
  - dispatch the hosted workflow
  - summarize the deterministic artifacts
- The operator must:
  - decide whether another run is required
  - give the final go/no-go
  - own the completion decision recorded in the human go/no-go workflow

## Completion Rule

The session is complete only when both of these are true:

- the diagnostics bundle for the selected target is available and reviewable
- a human decision is recorded in `tests/results/_agent/handoff/human-go-no-go-decision.json`

Machine success without the human decision is not session completion.
