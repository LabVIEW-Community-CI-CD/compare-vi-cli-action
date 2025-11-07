# Issue Draft – Complete Migration to VIPM CLI for Icon Editor Packaging

## Context
- Standing priority: **#593** — ensure all icon-editor packaging flows exercise the VIPM CLI path.
- Current branch has updated scripts/tests so lvlibp builds target LabVIEW 2023 while packaging runs under LabVIEW 2026 (VIPM CLI).

## Milestone
- **Milestone:** Execute a real VI Package build (VIPM CLI + LabVIEW 2026) and capture artifacts/manifest as acceptance evidence before closing #593.
  - Run locally or via CI once tooling lands.
  - Attach manifest/package hash summary to the issue comment or plan doc.

## Acceptance Checklist
- [ ] Merge CLI-only packaging changes (scripts, docs, tests).
- [ ] Update standing issue with the VIPM CLI milestone status and artifact links.
- [ ] Confirm replay/build helpers reference LabVIEW 2026 defaults.
- [ ] Validate unit suites (`Invoke-IconEditorBuild`, `IconEditorPackage`, `IconEditorDevMode`) stay green.
- [ ] Real VIP build milestone complete (see above).

## Preparation
- [ ] Ensure LabVIEW 2023 SP1 (32- & 64-bit) is installed for lvlibp builds and referenced in `configs/labview-paths.local.json` (see `configs/labview-paths.sample.json` for schema).
- [x] Install LabVIEW 2026 (64-bit) with VIPM CLI support; config updated (`configs/labview-paths.local.json`) with `C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe`.
- [ ] Verify VIPM CLI authentication/licensing on this workstation (launch `vipmcli --version` or equivalent) and document the CLI binary path.
- [x] Confirm VIPM CLI is available on PATH via `vipm --help` / `vipm version` (2026.1.0 Community Edition detected; no `VIPM_PATH` override required).
- [ ] Stage a working directory for build artifacts (default `.github/builds/VI Package`) and ensure sufficient disk space.

## Execution Plan (Real VIP Build)
1. Invoke the one-shot helper (runs rogue detection, close, vendor sync, dual VIPC apply, and build):
   ```powershell
   pwsh -File tools/icon-editor/Invoke-VipmCliBuild.ps1 `
     -RepoSlug 'LabVIEW-Community-CI-CD/labview-icon-editor' `
     -MinimumSupportedLVVersion 2023 `
     -ResultsRoot tests/results/_agent/icon-editor/vipm-cli-build
   ```
   The helper re-creates the vendor module wrappers and calls the vendored `ApplyVIPC.ps1`, which now shells directly into the VIPM CLI.
2. After completion, capture:
   - `manifest.json` path + checksum
   - VIP files emitted under `.github/builds/VI Package`
   - `package-smoke-summary.json`
   - Any diagnostic artifacts (`logs/gcli-*.log`, `missing-items.json`)
3. Record the run in issue #593 (brief note + SHA256 of the generated VIP).
4. Drop artifacts (manifest + summary + vip hashes) under `tests/results/_agent/icon-editor/` or attach to the issue for review.

## Open Questions / Blockers
- Does the current machine have LabVIEW 2026 beta + VIPM CLI installed? If not, who owns the install?
- Are there additional environment toggles (e.g., `ICON_EDITOR_BUILD_MODE`) required for CI parity?
- Should we schedule a CI validation run once the manual VIP build succeeds?
- **Current blocker:** g-cli build step still fails (`Error 1 … missing one or more source files`) even after applying the `runner_dependencies.vipc` via VIPM (32- & 64-bit). Need to inspect LabVIEW build logs or use the “Find Missing Items” tooling to identify which project references are unresolved before rerunning the package build.

## Follow-ups
- Consider adding an automated CI job that periodically runs the full packaging lane with VIPM CLI to avoid regressions.
- Evaluate whether fixture reports should include compiled VIP metadata for future diffing.

## Hardened Error Reporting Proposal (pending approval)
1. Persist g-cli stdout/stderr on failure (`tests/results/_agent/icon-editor/logs/gcli-<timestamp>.log`) and surface the log path from `Invoke-IconEditorProcess`.
2. Invoke a missing-items helper when lvlibp builds exit non-zero, writing `missing-items.json` alongside the build manifest.
3. Bubble the log + missing-items summary into the packaging failure exception and reference both artifacts here.

\n### Local artifact publishing\n- Run build via one-shot task (fast or robust).\n- Use new VS Code task 'IconEditor: Publish Local Artifacts' to zip outputs and optionally upload via gh release.\n- Artifacts remain in tests/results/_agent/icon-editor and are not checked into git.\n
