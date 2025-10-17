<!-- markdownlint-disable-next-line MD041 -->
# CI Orchestration Redesign Plan

> Objective: restore deterministic workflows while paving the way toward the > cross-platform .NET CLI runner that
> unifies LVCompare / telemetry logic.

## Current Pain Points

- **Duplicate Windows footprints** – `ci-orchestrated.yml` runs a hosted `windows-latest` preflight and the full self-
  hosted Pester suite. Shared composite actions (e.g., `ensure-invoker`) create scripts in `tests/results`, so hosted
  steps race with self-hosted runs and surface parser errors.
- **Shared results directory** – every Windows job writes to `tests/results`, mixing artifacts from
  dispatcher/schema/comparevi/loop categories. When retries are queued, late arrivals see inconsistent state.
- **Mixed platform assumptions** – Pester is cross-platform, but many categories still assume LVCompare lives on
  Windows. That blocks us from running the same logic on Linux/macOS ahead of the .NET CLI rollout.

## Design Principles

1. **Pester-first, platform-neutral** – tests must run anywhere PowerShell 7 + .NET CLI are available; LabVIEW-specific
   shims become optional layers.
2. **Deterministic outputs** – each job owns a unique results directory and writes provenance + session-index without
   stepping on other jobs.
3. **Explicit orchestration** – hosted/Windows responsibilities are modelled as separate jobs with zero shared state.
   Hosted jobs never try to launch the invoker or write invoker artifacts.
4. **Incremental CLI adoption** – migrate to the planned .NET compare runner in stages so we keep coverage while
   removing Windows-only assumptions.

## Execution Plan

### Phase 1 – Stabilise the existing workflow (in progress)

- Update `.github/actions/ensure-invoker` with an opt-in `requireInvoker` switch. Hosted gate jobs call it with
  `requireInvoker:false` (no wrapper emission; pure health check).
- Scope every Windows job to a unique results root. Example: `tests/results/dispatcher`, `tests/results/schema`, … This
  removes cross-job contamination.
- Introduce a hosted Windows gate job (`hosted-gate`) that runs ahead of the self-hosted matrix and prevents the invoker
  from launching when the hosted environment fails basic health checks.
- Gate all composite steps with platform checks (`if: runner.os == 'Windows'`) so Linux/macOS jobs never call LVCompare
  or invoker helpers.
- Verify deterministic artifacts by re-running orchestrated single strategy with identical inputs (`ts-<timestamp>-*`)
  and comparing provenance hashes.

### Phase 2 – Introduce the .NET CLI shim (started)

- Land the shared CLI (`CompareVI.Cli.dll`) that wraps LVCompare and telemetry emission. Expose a single entry point we
  can call from PowerShell (interim wrapper `tools/Invoke-CompareCli.ps1` already bridges to Pester while the .NET CLI
  is being built).
- Refactor Pester helper scripts to invoke the CLI instead of spawning LabVIEW/LVCompare directly. Retain Windows-
  specific fallbacks while the CLI develops parity.
- Add Linux/macOS jobs that run the CLI-only Pester categories. These jobs skip LVCompare-dependent tests until fixtures
  are ported.

### Phase 3 – Consolidate orchestrated paths

- Replace the hosted Windows preflight with a pure CLI smoke job (Linux + macOS). Enforce LVCompare presence only on the
  self-hosted runner.
- Collapse the `pester-category` fan-out into a single matrix driven by category name & OS, routed through the CLI.
- Simplify `windows-single` to a thin wrapper that downloads artifacts and publishes Dev Dashboard state; the CLI
  handles diffing/telemetry.

## Audit Checklist (in-flight)

- [ ] `ensure-invoker` updated with hosted opt-out
- [ ] Unique results directory per Windows job
- [ ] Hosted Windows jobs no longer spawn invoker scripts
- [ ] Deterministic orchestrated run verified (`gh run view …`)
- [ ] CLI prototype added (optional toggle via workflow variable)
- [ ] Linux/macOS Pester suites executing CLI tests
- [ ] Documentation updated (`docs/DEV_DASHBOARD_PLAN.md`, README)

## Risk & Mitigation

- **CLI parity gap** – Maintain Windows-only categories for LVCompare fixtures until the CLI exposes equivalent
  features. Mark remaining gaps in a separate tracker.
- **Self-hosted capacity** – Consolidating categories may stress the single runner. Add an optional matrix throttle
  (`max-parallel: 1`) to preserve determinism.
- **Artifact schema drift** – Ensure provenance/session-index schema updates are reviewed as part of the CLI migration
  to prevent consumer regressions.

---

This plan keeps Pester as the core test runner, removes the duplicated Windows surface, and gives us a clear path to the
cross-platform CLI without sacrificing the existing LVCompare integrations.
