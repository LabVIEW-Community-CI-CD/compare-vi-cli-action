# 594 – Harden LabVIEW host prep & MissingInProject reliability

## Summary

Prep/cleanup for the icon-editor MissingInProject flow still leaves rogue LabVIEW instances behind, which blocks the dev-mode integration suite and forces manual intervention. We recently added `Prepare-LabVIEWHost.ps1`, but it needs to become idempotent, capture deterministic close/open heuristics, and ship with tests + docs so anyone can prep a host and run the suite confidently (locally or in CI smoke jobs).

## Background / Motivation

- Local attempts to run `tests/IconEditorMissingInProject.DevMode.Tests.ps1` routinely hung because LabVIEW stayed open after token writes or reset steps (`LabVIEWCLI` “already closed” messages while PIDs lingered).
- The new host-prep helper helps, but it still assumes a clean slate; rerunning it after a failure often triggers more g-cli launches and leaves additional LabVIEW processes alive.
- Without deterministic prep we can’t reliably reproduce or debug MissingInProject regressions, and future automation (e.g., running the suite in CI) will inherit the same flakiness.

## Proposal

1. **Idempotent host prep**
   - Make `Prepare-LabVIEWHost.ps1` safe to rerun whether we start from a built VIP or straight from vendor source. When `-SkipStage` is set, the helper should no longer require `-FixturePath`.
   - Detect existing snapshots/dev-mode state, only re-enable dev mode when necessary, and verify LabVIEW shutdown (LabVIEWCLI → `tools/Close-LabVIEW.ps1` → `Stop-Process` fallback) before returning success.
   - Emit structured telemetry (`tests/results/_agent/icon-editor/host-prep/*.json`) with versions, bitness, steps executed, close retries, and any forced terminations.

2. **Close/open heuristics + unit coverage**
   - Factor the timeout/retry logic into helpers with configurable waits (including the “initial wait → forced termination” path) and reuse them in host prep, build, and validation scripts.
   - Extend `tests/Prepare-LabVIEWHost.Tests.ps1` (or new suites) to cover mixed version/bitness parsing, skip flags, dry-run behavior, fixture-optional scenarios, and the shutdown heuristics (using stubs).

3. **Build + validate from source**
   - Provide a single-script / VS Code task that performs the source-first flow: prep host (no staging), enable dev mode, install VIPM deps, build lvlibp (32/64), create the VIP (2026/64), run `Invoke-ValidateLocal.ps1` on the newly built VIP, and then disable dev mode/reset.
   - Ensure each phase records telemetry (inputs, outputs, closure attempts) so failures can be diagnosed without rerunning everything.

4. **MissingInProject reliability**
   - Ensure the dev-mode integration suite runs end-to-end on the source-first host prep (no VIP). Document required LabVIEW versions, VIPM CLI, and environment toggles.
   - Add a dry-run/smoke mode (e.g., skip lvlibp build) for faster feedback when diagnosing prep issues.

5. **Tooling & docs**
   - Update VS Code tasks:
     - “Prepare LabVIEW Host (fixture)” for hermetic validation when required.
     - “Prepare LabVIEW Host (source)” for the source-first flow (skip staging).
     - “IconEditor: Build & Validate (Source)” that chains prep + build + validation.
   - Expand `docs/ICON_EDITOR_PACKAGE.md` / `docs/DEVELOPER_GUIDE.md` with a “Source build & host prep” section (checklist, troubleshooting, VIP output paths).
   - Add guidance to `AGENT_HANDOFF.txt` so every agent knows which task to run before touching MissingInProject or the build lane.

6. **Telemetry / optional CI smoke**
   - Track prep/build outcomes over time (success/failure counts, forced closes) so we can spot regressions.
   - Evaluate a nightly/manual workflow that runs the source-first helper in `-DryRun` mode to catch script regressions even on machines without LabVIEW.

## Acceptance Criteria

- Running `pwsh tools/icon-editor/Prepare-LabVIEWHost.ps1 -SkipStage -Versions 2021 -Bitness 32,64` (source flow) or `-FixturePath <vip>` (fixture flow) multiple times in a row is idempotent (same summary, no orphaned LabVIEW.exe, telemetry logged).
- The helper consistently closes LabVIEW before returning success (verified via rogue detector or explicit PID checks).
- Unit tests cover version parsing, skip flags, dry-run behavior, fixture-optional flows, and the shutdown heuristics (including the escalation path to `Stop-Process`).
- A single VS Code task (or script) performs the end-to-end source-first build + validation flow and outputs the built VIP path, host-prep telemetry path, and Pester summary locations.
- `tests/IconEditorMissingInProject.DevMode.Tests.ps1` completes on the reference host after using the source-first helper; any remaining failures are actionable (no “LabVIEW still open” noise).
- Documentation + VS Code tasks describe both fixture-based and source-first workflows, and `AGENT_HANDOFF.txt` references the new tasks.
- Telemetry files under `tests/results/_agent/icon-editor/host-prep/` (and build/package summaries) capture each run’s parameters/outcome.
- (Optional) A CI smoke or scripted dry-run validates the helper so regressions surface quickly.
