# ADR 0002: Agent Flow 1.1.0 — Deterministic Locking and DX Improvements

- Status: Accepted
- Date: 2025-10-09
- Issue: #88

## Context

Self-hosted Windows checks (Pester, Fixture Drift, Orchestrated) were prone to:

- Overlap on a single runner, causing leaked `LabVIEW.exe`/`LVCompare.exe`/`pwsh.exe` processes and flaky runs.
- Heartbeat implementation spawning background `pwsh` jobs that could be orphaned on cancellation.
- Preflight fragility (interactive LabVIEW instances, inconsistent cleanup policy).
- LV notice directory assertions failing hard when CompareVI did not run (e.g., earlier failures or path variance).
- Inconsistent developer experience (re-run paths, provenance, and summaries differ across workflows).

## Decision

Adopt “Agent Flow 1.1.0 (DX)” for deterministic, developer-friendly operation:

1) Deterministic session locking
- Use `tools/Session-Lock.ps1` with group `pester-selfhosted` for all heavy Windows jobs.
- Queue deterministically with backoff/heartbeat; lock is released in a finally path.

2) Preflight hygiene and cleanup
- Standardize cleanup via repo vars: `CLEAN_LV_BEFORE=true`, `CLEAN_LV_AFTER=true`, `CLEAN_LV_INCLUDE_COMPARE=true`.
- Run `runner-unblock-guard` pre/post with cleanup gating; fail fast if `LabVIEW.exe` is running.

3) Inline heartbeat (no background jobs)
- Replace Start-Job-based heartbeat with inline writes in `Invoke-PesterTests.ps1` to avoid orphan `pwsh.exe`.

4) Warmup normalization
- Forward `tools/Warmup-LabVIEW.ps1` to `Warmup-LabVIEWRuntime.ps1`, default bitness from env/64, and guard `$LASTEXITCODE` propagation.

5) LV notice directory UX
- Use `LV_NOTICE_DIR` if present; otherwise search `results/fixture-drift/**/_lv` and log fallback.
- Treat missing notice dir as notice-only except in strict single-launch assertion; print a clear reason code when strict.

6) Unified DX across workflows
- Add re-run hint and provenance blocks to Pester and Fixture Drift (not only orchestrated).
- Summaries include current state: runner busy, lock status (`LockId`/age), LVCompare path, idle LV result, notice dir path/fallback, heartbeat stats.

## Consequences

- Pros: determinism on a single runner, fewer leaks, consistent developer experience, reproducible runs, clearer failure modes.
- Cons: serialized queue introduces latency; stricter preflight may fail fast requiring runner cleanup; minimal overhead to show summaries and provenance.

## Notes

- This ADR builds on ADR 0001 (Step-Based Pester Invoker) and formalizes lock+cleanup+DX patterns.
- Post-adoption, enable merge queue on `develop` after several fully green cycles to serialize landings.

## References

- ADR 0001: docs/adr/0001-single-invoker-step-module.md
- Requirements: docs/requirements/AGENT_FLOW_1_1_0.md

