# Investigation Plan: Automate LVCompare Config Scaffolding (#551)

Objective

- Provide a helper that discovers LVCompare/LabVIEWCLI installs and scaffolds `configs/labview-paths.local.json` so
  local diff sessions can run in real mode without manual edits.

Planned work

- `tools/New-LVCompareConfig.ps1` (name TBD) to:
  - Detect LabVIEW/LVCompare/LabVIEWCLI paths via VendorTools heuristics (Program Files scan, env vars, existing config entries).
  - Prompt for confirmation/override and write `configs/labview-paths.local.json` (git-ignored).
  - Optionally run `Verify-LVCompareSetup.ps1 -ProbeCli` after writing the config.
- `tools/Verify-LocalDiffSession.ps1` enhancements:
  - Offer `-AutoConfig` to invoke the helper automatically when `-ProbeSetup` fails.
  - Improve warning messages to suggest the helper when setup isn’t ready.
- Documentation updates (README/TROUBLESHOOTING) with a short "generate config" walkthrough.
- Tests:
  - Stub-backed Pester test that simulates config creation in a temp directory.
  - Additional coverage to ensure `-AutoConfig` integrates cleanly with the local diff session helper.
- Provide a stateless option (`-Stateless`) so Verify-LocalDiffSession can drop the generated
  config after each run for users who prefer fresh detection.
- Bubble `-LabVIEWVersion` / `-LabVIEWBitness` through Verify-LocalDiffSession so auto-config can
  target the intended install (e.g., LabVIEW 2025 64-bit) without post-run edits.
- Canonicalise LVCompare resolution to the 64-bit shared path
  (`C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`) so diff capture
  never falls back to the 32-bit binaries.
- Provide a wrapper (`Run-LocalDiffSession.ps1`) that runs the helper and stages artefacts/zips in a
  predictable location for immediate inspection.
- Default local diff runs should capture the full signal (no ignore flags) and surface an explicit
  `-NoiseProfile legacy` switch for callers that still need the historical suppression bundle.

Open questions

- Helper now records a `versions` map automatically; confirm downstream callers
  prefer the first match or allow selection when multiple installs exist.
- How to best handle environments where LabVIEWCLI isn't installed (e.g., warn vs. stub mode fallback)?
