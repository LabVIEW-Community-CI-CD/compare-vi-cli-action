<!-- markdownlint-disable-next-line MD041 -->
# Post-Release Follow-Up Items (v0.6.5 -> v0.6.6 Planning)

**Status**: `v0.6.5` packages the compare-timeout guard and the verified native
wrapper proof. The items below are the remaining maintenance backlog after that
cut, not prerequisites for publishing `v0.6.5`.

## Completed In v0.6.5

### ✅ Guarded native compare runtime

- Added `compare-timeout-seconds` to the composite action contract.
- Added bounded wait handling in `scripts/CompareVI.psm1` with deterministic
  timeout exit code `124`.
- Added focused timeout coverage in `tests/CompareVI.Timeout.Tests.ps1`.

### ✅ Specialized LV32 wrapper budget tuning

- Tuned `.github/workflows/labview-cli-compare.yml` to a `1200` second compare
  budget after observing that successful native compares can legitimately take
  about 10 minutes on the specialized runner.
- Confirmed the tuned workflow still reaches `Runner Unblock Guard` on a live
  successful run.

### ✅ Release packet refresh

- Updated changelog, stable-pin docs, active release helper docs, and archived
  release notes to reflect `v0.6.5`.
- Replaced the stale `v0.5.0` planning backlog in this tracker.

## Deferred Follow-Ups

### ⏸️ Follow-Up 1 – Publish and repin certified consumers

- Publish `v0.6.5` and repin certified downstream consumers that should track
  the new stable maintenance baseline.
- Re-run downstream proving after those pins move.

### ⏸️ Follow-Up 2 – Extend timeout guard only where live evidence justifies it

- Review other self-hosted compare workflows before copying the timeout guard.
- Require a real stranded-runner symptom or repeated long-running evidence
  rather than blanket timeouts across every lane.

### ⏸️ Follow-Up 3 – Timeout telemetry enrichment

- If operators need richer postmortem evidence, project `timedOut` and
  timeout-budget fields into downstream scorecards or release evidence packets.
- Keep the action outputs additive if this lands.

### ⏸️ Follow-Up 4 – Release archive/index hygiene

- Revisit whether additional archived release notes should be surfaced through
  `docs/documentation-manifest.json` beyond the recent release lines captured
  today.

---

## Summary

- **Completed in v0.6.5**: compare timeout guard, tuned specialized workflow
  budget, refreshed release packet.
- **Deferred**: publish/repin, selective rollout to other workflows, telemetry
  enrichment, archive/index hygiene.
- **Last updated**: 2026-03-29.
