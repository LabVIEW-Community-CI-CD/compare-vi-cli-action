# LabVIEW Runtime Gating

_Updated 2025-10-07 – tracked under #88_

## Overview

Warm-up now deliberately leaves `LabVIEW.exe` running so later steps can take
immediate ownership without incurring the full start-up cost. To keep runs
deterministic we treat the presence of LabVIEW as a “runtime lock”: new phases
must either accept the existing instance (when it is the one they expect) or
explicitly reset it.

The gating model rests on three data sources:

1. **Warm-up snapshot** - `tools/Agent-Warmup.ps1` writes
   `tests/results/_warmup/labview-processes.json`
   (`labview-process-snapshot/v1`) capturing LabVIEW **and** LVCompare processes
   (PID, start time, working set, CPU totals).
2. **Phase guards** -  `tools/Guard-LabVIEWPersistence.ps1` records 
   pre/post process counts in  `results/**/_wire/labview-persistence.json` 
   and marks  `closedEarly=true` if LabVIEW or LVCompare disappear during a guarded window. 
3. **CompareVI cleanup** - when  `ENABLE_LABVIEW_CLEANUP=1` CompareVI waits up to 
   90 seconds before force-closing any newly spawned LabVIEW PIDs.

## Guidelines for Agents

1. **Inspect the snapshot**  
   Check  `tests/results/_warmup/labview-processes.json`. A stable warm-up 
   instance will show the same PID across snapshots with minimal CPU growth for
   both LabVIEW and LVCompare. Action items on the Dev Dashboard surface the
   counts and PID lists.
2. **Compare guards**  
2. **Compare guards**  
   For fixture drift and long-running compare phases, open
    `results/fixture-drift/_wire/labview-persistence.json`. If you see 
    `closedEarly=true` or new PIDs appear unexpectedly (LabVIEW or LVCompare), pause and decide whether 
   to re-run warm-up or stop processes before continuing.
3. **Reset vs reuse**  
   - _Reuse_ when the snapshot matches expectations (same PID, reasonable
     footprint, no guard warnings). Proceed to the next phase without extra
     cleanup.
   - _Reset_ by invoking `Stop-LabVIEWProcesses` followed by
     `tools/Warmup-LabVIEWRuntime.ps1` if the snapshot looks suspicious or you need a
     pristine LabVIEW state.

4. **Always append observations**  
   If you intervene (e.g., terminate LabVIEW manually), add a note to the step
   summary or PR so downstream agents know the latest state.

## Dashboard Integration

- `tools/Dev-Dashboard.ps1` now renders a “LabVIEW Snapshot” section in both
  JSON and HTML outputs, showing the current process list.
- Action items include a `LabVIEW` category entry when warm-up leaves an
  instance running, pointing to the snapshot path.

## Q&A

**Why leave LabVIEW running at all?**  
Startup dominates compare time on self-hosted runners. Keeping one instance alive
improves responsiveness, provided we track ownership.

**Can LabVIEW still be closed automatically?**  
Yes. Set `ENABLE_LABVIEW_CLEANUP=1` before running CompareVI. We relaxed the wait
window to 90 seconds to allow gentle shutdown; if the cleanup is disabled the
instance remains for manual inspection.
LVCompare processes are captured in the warm-up snapshot so you can confirm they exited as expected.

**How do I spot rogue LabVIEW?**  
Use `tools/Detect-RogueLV.ps1` or review the guard JSON. Any PID not in the
warm-up snapshot or flagged as closed early should be treated as suspect.

## Next Steps

- Consider adding dashboard tiles that diff current vs previous snapshots.
- Explore auto-tagging snapshots with CI job IDs for quick correlation.
- Feed LabVIEW snapshot metadata into Guard-LabVIEWPersistence to highlight
  runaway memory/CPU trends.
