<!-- markdownlint-disable-next-line MD041 -->
# Issue 134 – Provider registry rollout

## Summary

Refactor the VS Code extension from the current CompareVI-only experience into the generic "N providers"
companion described in the repo. Land the provider registry, shared services (status bar, telemetry, health
checks), and the enriched panel so future providers (g-cli, TestStand harness, etc.) can plug in without
further architectural work.

## Why

- Matches the abstraction used by the TestStand harness (provider selected at runtime).
- Gives immediate UX wins: provider switcher, diagnostics, status bar, reusable presets, telemetry
  breadcrumbs.
- Establishes automated testing so new providers do not regress existing workflows.

## Acceptance Criteria

- [ ] Introduce a provider registry/context and migrate the CompareVI provider onto it without regression.
- [ ] Add a stub g-cli provider (or similar) to exercise provider switching in the UI.
- [ ] Implement health checks: LabVIEW.ini presence + snapshot, g-cli executable detection with warnings or
      disabled state when absent.
- [ ] Persist the LabVIEW.ini snapshot (and other provider config breadcrumbs) alongside compare artifacts;
      emit telemetry events for every run (respect opt-in/out).
- [ ] Enhance the panel UI: provider switcher, commit ref inputs with swap, preset CRUD, CLI preview
      (copy/open), image thumbnails, status bar spinner + toggle.
- [ ] Update unit/integration tests (including multi-root + g-cli warning path) and keep
      `npm run test:unit`, `npm run test:ext` green via the CLI harness.
- [ ] Update docs (README/CONTRIBUTING) and mark this issue as the standing priority (superseding #127).

## Testing Guidance

- `npm run test:unit` — provider registry, state builder, telemetry, health check helpers (≥80% coverage).
- `npm run test:ext` — manual/commit compare, provider switching, status bar toggle, presets, g-cli stub,
  multi-root behaviour, artifact snapshots.
- Optional: add a "dry run" flag for the harness if CI needs a quick sanity check.

## Non-Goals

- Shipping a full g-cli/TestStand provider beyond the stub.
- Telemetry upload outside local logs.
- Deep UI polish beyond the required controls.

### Handoff sync idempotency + guard test

#### Summary recap

- Make standing-priority sync deterministic and idempotent.
- Remove duplicate banner output in handoff logs.
- Embed standing-priority snapshot/router in session capsules.
- Add guard test to prevent re-sync/retry noise on repeated runs.

#### Changes

- `AGENTS.md`: Primary directive now references the standing-priority label and `.agent_priority_cache.json`.
- `AGENT_HANDOFF.txt`: Context line points to `priority:sync` plus cache usage.
- `tools/Print-AgentHandoff.ps1`:
  - New helpers: `Ensure-StandingPriorityContext`, `Invoke-StandingPrioritySync`.
  - Skip `gh` sync when cache + snapshot + router are healthy.
  - Single banner output; add `standingPriority` node to the session capsule.
- `tests/AgentHandoff.Idempotency.Tests.ps1`: Verifies a second run does not re-sync or emit retry notices.

#### Impact

- Stable startup logs in offline/restricted environments.
- Deterministic session artifacts for downstream agents and CI summaries.

#### Next

- Optional: add a negative-path test that forces a cache miss and asserts a single retry.
- Wire wrapper-based integration run (TestStand harness) for end-to-end assertion.

Refs: #134
