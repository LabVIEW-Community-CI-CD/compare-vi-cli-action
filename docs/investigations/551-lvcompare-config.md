# Investigation Plan: Automate LVCompare Config Scaffolding (#551)

Objective
- Provide a helper that discovers LVCompare/LabVIEWCLI installs and scaffolds `configs/labview-paths.local.json` so local diff sessions can run in real mode without manual edits.

Planned work
- `tools/New-LVCompareConfig.ps1` (name TBD) to:
  - Detect LabVIEW/LVCompare/LabVIEWCLI paths via VendorTools heuristics (Program Files scan, env vars, existing config entries).
  - Prompt for confirmation/override and write `configs/labview-paths.local.json` (git-ignored).
  - Optionally run `Verify-LVCompareSetup.ps1 -ProbeCli` after writing the config.
- `tools/Verify-LocalDiffSession.ps1` enhancements:
  - Offer `-AutoConfig` to invoke the helper automatically when `-ProbeSetup` fails.
  - Improve warning messages to suggest the helper when setup isn’t ready.
- Documentation updates (README/TROUBLESHOOTING) with a short “generate config” walkthrough.
- Tests:
  - Stub-backed Pester test that simulates config creation in a temp directory.
  - Additional coverage to ensure `-AutoConfig` integrates cleanly with the local diff session helper.

Open questions
- Should we support per-version configs (multiple LabVIEW installations) or only the dominant install?
- How to best handle environments where LabVIEWCLI isn’t installed (e.g., warn vs. stub mode fallback)?
