<!-- markdownlint-disable-next-line MD041 -->
# Post-Release Follow-Up Items (v0.6.6 Closeout)

**Status**: `v0.6.6` is published, immutable, and backed by both the protected
`verify-existing-release` replay and the certified consumer rollout on
`LabviewGitHubCiTemplate/develop`. The items below are the remaining optional
maintenance backlog after that cut, not blockers for the shipped baseline.

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

## Completed In v0.6.6

### ✅ Follow-Up 1 – Publish and repin certified consumers

- Published immutable release `v0.6.6` and closed the release-contract repair
  path through:
  - release conductor run `23720581794`
  - publish run `23720604131`
  - downstream proving repair run `23720719499`
  - protected replay run `23720737438`
- Repinned the certified downstream consumer
  `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` through PR `#51`.
- Re-ran the upstream onboarding feedback workflow against the merged consumer
  baseline:
  - workflow run `23721023554`
  - `status=success`

## Deferred Follow-Ups

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

- **Completed in v0.6.6**: immutable publication, release-contract repair,
  certified consumer repin, hosted downstream drift proof.
- **Deferred**: selective rollout of timeout controls, telemetry enrichment,
  archive/index hygiene.
- **Last updated**: 2026-03-29.
