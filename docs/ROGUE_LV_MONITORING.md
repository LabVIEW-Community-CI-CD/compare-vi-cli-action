# Rogue LabVIEW Monitoring

To keep LabVIEW/LVCompare instances from lingering between runs, both the Pester
dispatcher and the Icon Editor helper scripts now call the shared
`tools/Detect-RogueLV.ps1` watchdog.

- **Pester (`Invoke-PesterTests.ps1`)** runs the detector before the suite
  starts and again after completion. Detected processes are recorded under
  `tests/results/_agent/rogue-lv/` and summarized in the GitHub Step Summary.
  Set `SKIP_ROGUE_LV_DETECTION=1` or pass `-DisableRogueDetection` only when the
  host cannot access the helper.

- **Icon Editor helpers** (`Enable-DevMode.ps1`, `Disable-DevMode.ps1`, and
  `Close-IconEditorLabVIEW`) invoke the detector around their g-cli work. When a
  rogue LabVIEW session is found they automatically run `tools/Close-LabVIEW.ps1`
  and rerun the detector before proceeding.

If the detector still finds rogue processes after the retry it fails the
current command, keeping the workspace in a known-good state for the next task.

## LabVIEW CLI contract

Always invoke LabVIEW via `labviewcli`/`g-cli`. Never launch `LabVIEW.exe`
directly from scripts or tests—the CLI is responsible for locating and closing
the IDE, and every direct spawn risks leaving rogue LabVIEW sessions running.
