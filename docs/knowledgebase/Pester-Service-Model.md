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
- `tools/PesterExecutionPacks.ps1`
  - shared named execution-pack catalog and resolution contract used by selection,
    direct dispatcher use, and local-first entrypoints
- `tools/Invoke-PesterExecutionPostprocess.ps1`
  - execution-post contract for XML integrity classification and machine-readable summary repair
- `tools/Invoke-PesterExecutionFinalize.ps1`
  - finalize contract for summary, artifact manifest, session index, compare-report indexing, and leak-report materialization from dispatcher-owned raw outputs
- `tools/Invoke-PesterExecutionPublication.ps1`
  - publication contract for step-summary, session-summary, diagnostics, and operator-facing metadata outside the dispatcher
- `tools/Invoke-PesterExecutionTelemetry.ps1`
  - durable telemetry contract that normalizes `dispatcher-events.ndjson` and handshake markers into `pester-execution-telemetry.json`
- `tools/PesterServiceModelSchema.ps1`
  - shared schema-governance contract that validates retained receipts and derived artifacts before replay, postprocess, or evidence consumers trust them
- `tools/PesterFailurePayload.ps1`
  - shared failure-detail contract that keeps dispatcher, finalize, step-summary, and top-failure readers on the same canonical payload and unavailable-details semantics
- `tools/PesterPathHygiene.ps1`
  - local path-hygiene contract that classifies synchronized or externally managed roots before the harness writes results or acquires session locks
- `tools/Invoke-PesterEvidenceClassification.ps1`
  - shared evidence-classification contract used by the hosted evidence workflow and local retained-artifact replay
- `tools/Invoke-PesterOperatorOutcome.ps1`
  - shared operator-outcome contract that turns evidence classification into machine-readable gate status, reasons, and next-action guidance
- `tools/Invoke-PesterEvidenceProvenance.ps1`
  - shared provenance contract that records exact source raw artifacts, receipt identity, run context, and derived evidence outputs for hosted evidence and local replay
- `tools/Write-PesterTotals.ps1`
  - shared totals writer used by hosted evidence and local replay
- `docs/pester-service-model-promotion-comparison.json`
  - retained requirement-to-run comparison packet used by the promotion dossier to compare representative named packs against the current baseline
- `tools/Replay-PesterServiceModelArtifacts.Local.ps1`
  - local retained-artifact replay entrypoint for postprocess, summary, totals, session index, and evidence classification without rerunning dispatch
- `tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1`
  - bounded local Windows-container surrogate that records whether Docker Desktop Windows engine plus the pinned NI Windows image are ready before another hosted rerun is chosen

## Design Rules

- Context certifies repo/control-plane assumptions. It does not probe host readiness or execute tests.
- Selection resolves integration mode, include patterns, and dispatcher profile into a receipt before execution begins.
- Selection should resolve a named execution pack or test group as the operator-facing contract. `IncludePatterns` may refine a declared pack, but they should not remain the only externally visible control surface.
- The named execution-pack contract currently exposes `full`, `comparevi`, `dispatcher`, `workflow`, `fixtures`, `psummary`, `schema`, and `loop`.
- Selection consumes context. It does not probe host readiness or invoke the dispatcher.
- Readiness certifies the environment. It does not execute the test pack.
- Readiness consumes context. It does not discover standing-priority state itself.
- Readiness emits a bounded-freshness receipt artifact that execution must download and validate before dispatch.
- Execution consumes context, selection, and readiness. It does not normalize pack inputs, choose the dispatcher profile, bootstrap Docker runtimes, install core toolchains, or discover standing-priority state.
- Execution writes an execution receipt before uploading raw artifacts so evidence can classify the real seam outcome.
- Execution must also emit a skip-safe execution contract from an always-on finalize path so reusable-workflow outputs do not collapse when the execution job never starts.
- Execution must preserve control-plane outputs even when in-process tests mutate workflow environment variables; dispatcher exit-code evidence must remain recoverable from a durable trace.
- Long-running execution should emit durable progress telemetry so operators can inspect forward progress even when GitHub withholds live logs until job completion. The retained contract is `pester-execution-telemetry.json`, derived from `dispatcher-events.ndjson` plus handshake markers.
- Execution-post shall classify `results-xml-truncated`, `invalid-results-xml`, and `missing-results-xml` explicitly instead of collapsing XML integrity debt into generic `seam-defect`.
- Local iteration must not depend on the workflow shell. The local harness should
  make the execution slice runnable on its own while keeping the same preflight
  and receipt boundaries.
- `PathHygieneMode` supports `auto`, `relocate`, `block`, and `off`. The
  default local mode is `auto`: risky OneDrive-like roots relocate to a safe
  local root, while `block` emits `status=path-hygiene-blocked` from a safe
  receipt root before dispatch starts.
- Local iteration must also avoid synchronized or externally managed roots for results and session-lock state. OneDrive-like paths are path-hygiene risk unless the harness explicitly relocates or blocks them before dispatch.
- Retained raw and contract artifacts should be treated as replay inputs. Non-host-dependent layers should be reproducible locally from mounted artifacts instead of forcing another GitHub run.
- Representative retained-artifact replay should stay current with real GitHub seams, not only synthetic fixtures. Schema-lite summaries and legacy receipts missing optional pack fields should normalize into current contracts instead of crashing replay.
- When a live local proof is needed, the Windows-container surrogate should be checked first. The bounded local commands are `tests:windows-surface:probe`, `docker:ni:windows:bootstrap`, and `compare:docker:ni:windows:probe`.
- A reachable Windows host bridge from WSL or another Unix coordinator should be consumed before the packet emits a host-unavailable Windows-surface escalation.
- Receipt and artifact schemas are part of the control plane. Readers should validate compatible schema versions explicitly and fail closed on unsupported changes.
- `unsupported-schema` is a first-class execution or evidence outcome. Execution-post, hosted evidence, and local replay should surface that classification with contract-specific reasons such as `execution-receipt-unsupported-schema` or `pester-summary-unsupported-schema-version`.
- Evidence consumes raw execution output plus the execution receipt. It must first normalize the downloaded raw artifact into the canonical evidence workspace, then classify `context-blocked`, `readiness-blocked`, and `seam-defect` explicitly instead of collapsing them into one execution symptom.
- Evidence should also materialize `pester-operator-outcome.json` so machine consumers and humans see the same gate status, classification, reasons, and next-action guidance.
- Derived evidence and promotion artifacts should retain provenance to the exact raw artifacts, receipts, runs, and refs they were generated from.
- The canonical provenance surfaces are `pester-evidence-provenance.json`,
  `release-evidence-provenance.json`, and
  `promotion-dossier-provenance.json`.
- The canonical promotion-comparison surface is
  `pester-service-model-promotion-comparison.json`.
- Failure detail is a versioned interface, not a convenience file. Readers must accept current and legacy payload shapes and degrade truthfully when summary counts show failures but detail entries are unavailable.
- Failure detail also has a producer-side truth requirement: execution must not emit `failed > 0` alongside an empty detail payload unless it also emits an explicit unavailable-details state that evidence can surface.
- The canonical producer payload is `pester-failures@v2`. It carries `detailStatus`, `detailCount`, optional `unavailableReason`, and normalized `results` entries so local and CI readers can surface the same truth without guessing from an empty array.
- The canonical summary fields are `failureDetailsStatus`, `failureDetailsCount`, and `failureDetailsReason`. Those fields let machine-readable consumers distinguish real zero-failure cases from degraded or unavailable detail capture.
- Dispatch now stops at test execution and immediate machine capture. Summary emission, session indexing, leak reporting, artifact manifest generation, and step-summary or publication behavior are owned by explicit finalize, postprocess, and evidence helpers so `Invoke-PesterTests.ps1` no longer owns the operator-facing side effects directly.
- Common operator workflows should be exposed through stable named entrypoints or wrappers rather than forcing maintainers to remember raw dispatcher arguments for each pack.
- Stable local-first entrypoints now include `tests:pack:comparevi`, `tests:pack:dispatcher`, and `tests:pack:workflow`, which route through the same named execution-pack contract as CI.
- The retained-artifact replay entrypoint is `tests:replay:local`. It stages a mounted raw artifact plus a retained execution receipt into a local workspace and rebuilds postprocess, totals, session index, and evidence outputs without rerunning the full workflow.
- The representative retained-artifact replay entrypoint is `tests:replay:representative`. It replays a reduced live-run fixture with truncated XML and schema-lite summary so replay compatibility regressions are caught locally before another GitHub run.
- Local replay also materializes or reuses `pester-execution-telemetry.json`, so retained artifacts can surface last-known phase and event counts without rerunning dispatch.
- When the gate fails, the operator should get an explicit classification, reason chain, and next-step context before the job exits nonzero.
- The canonical machine-readable operator surface is `pester-operator-outcome.json`. Step summary, top-failure rendering, replay, and gate propagation should consume that same outcome contract instead of inventing divergent failure wording.
- Local autonomy should also be bounded by the packet: local CI should emit a ranked requirement backlog and a selected next requirement so LLM-driven development stays inside the declared assurance surface.
- Local autonomy should be policy-driven, not improvised. The local CI loop should record active worktree matches, preferred commands, stop conditions, and escalation conditions so an agent knows when to keep iterating locally and when to seek hosted proof.
- Local autonomy should also consume proof checks, not just RTM status. The loop should reopen implemented requirements when proof checks regress, while `pester-windows-container-surface.json` records whether the Windows-container surrogate is ready, advisory, or unavailable from the current host.
- When the next truthful proof surface is unavailable from the current host, local autonomy should emit a machine-readable escalation step instead of a human-only advisory. The canonical handoff artifact is `pester-service-model-next-step.json`.
- When more than one local proof packet exists, the shared program selector should reconcile them into one next step. Requirement work still outranks escalations, and shared `windows-docker-desktop-ni-image` escalations should merge into one `comparevi-local-program-next-step.json` handoff instead of competing packet advisories.
- The existing required gate remains in place until the pilot proves equivalent or better behavior.
- Trusted PR proving must stay on `pull_request_target` with same-owner gating. Cross-owner fork heads are not allowed to drive self-hosted execution.

## Promotion Rule

The pilot can replace the monolith only after:

- readiness receipts are stable on the ingress host
- selection receipts resolve the declared pack and dispatcher profile without execution-side drift
- execution runs the declared pack without host bootstrap
- evidence produces deterministic classifications
- retained promotion evidence compares representative named packs against the current baseline
- PR/release comparisons show better failure localization and lower operator ambiguity

## Promotion Packet

The current upstream promotion packet for the pilot is hosted-first:

- `docs/requirements-pester-service-model-srs.md`
- `docs/rtm-pester-service-model.csv`
- `.github/workflows/pester-service-model-quality.yml`
- `.github/workflows/pester-service-model-release-evidence.yml`
- `tools/priority/pester-service-model-local-ci.mjs`
- `tools/priority/pester-service-model-autonomy-policy.json`
- `tests/results/_agent/pester-service-model/local-ci/pester-service-model-next-step.json`
- `tools/priority/comparevi-local-program-ci.mjs`
- `tests/results/_agent/local-proof-program/local-ci/comparevi-local-program-next-step.json`

That packet is derived from the retained fork dossier on `#2078` and is used to
justify the next minimal upstream slice on `#2069`.
