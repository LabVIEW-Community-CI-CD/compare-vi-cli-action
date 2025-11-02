# Icon Editor VI Package Audit

This note records what ships inside the committed fixture `tests/fixtures/icon-editor/ni_icon_editor-1.4.1.948.vip` and
how it maps back to sources in this repository or the upstream `ni/labview-icon-editor` project. Use it as a quick
reference when verifying future package builds or investigating regressions.

## Inspecting the fixture locally

```powershell
$vip = 'tests/fixtures/icon-editor/ni_icon_editor-1.4.1.948.vip'
$scratch = 'tmp/icon-editor/ni_icon_editor-1.4.1.948'
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $vip -DestinationPath $scratch
Expand-Archive -Path (Join-Path $scratch 'Packages/ni_icon_editor_system-1.4.1.948.vip') `
  -DestinationPath (Join-Path $scratch 'Packages/ni_icon_editor_system')
```

The outer package (`ni_icon_editor`) contains the custom action VIs and a nested `ni_icon_editor_system` VIP that carries
the actual LabVIEW payload.

## Package layout highlights

- **Top-level files** – `PreInstall.vi`, `PostInstall.vi`, `PreUninstall.vi`, `PostUninstall.vi`, `icon.bmp`, and
  `spec` (the VIP metadata). These wire into VIPM’s custom action hooks.
- **Nested package** – `Packages/ni_icon_editor_system-1.4.1.948.vip` plus its own `spec`.
- **Deployment payload** (inside `Packages/ni_icon_editor_system/.../LabVIEW Icon Editor`):
  - `install/temp/lv_icon_x64.lvlibp` and `install/temp/lv_icon_x86.lvlibp` (built PPLs for 64-bit and 32-bit LabVIEW).
  - `Tooling/deployment/NI Icon editor.vipb`, `runner_dependencies.vipc`, Release Notes, and the four VIP custom action
    VIs.
  - Unit-test suites under `Test/Unit Tests/*` and support scripts such as `scripts/update_readme_hours.py`.
  - Historical telemetry (e.g., `reports/git-hours-2025-07-24.txt`).

Both `spec` files report version **1.4.1.948**, license **MIT**, and list the same release note history that is generated
during the upstream CI build.

## Comparison with repository sources

- ✅ The four VIP custom action VIs match byte-for-byte the restored copies in
  `vendor/icon-editor/.github/actions/build-vi-package/` (verified via SHA-256 hashes).
- ✅ `runner_dependencies.vipc` in the package aligns with the file mirrored under
  `vendor/icon-editor/.github/actions/apply-vipc/`.
- ⚠️ The packaged script `scripts/update_readme_hours.py` and the bundled unit-test suites are not mirrored in this
  repository. They currently live only inside the VIP artifact.
- ⚠️ The built PPLs (`lv_icon_x64.lvlibp`, `lv_icon_x86.lvlibp`) are generated outputs; we do not track reference copies
  or hashes in-source, so reproducibility checks rely on inspecting a produced package.

## Follow-up opportunities

- Add a lightweight helper (PowerShell or Node) that expands a VIP and records a manifest (hashes, sizes) so Validate
  can diff future builds automatically.
- Decide whether key assets that only live inside the package (e.g., `update_readme_hours.py`, unit-test directories)
  should be mirrored under `vendor/icon-editor/` for easier diffing, or if documenting their presence is sufficient.
- Capture golden hashes for the 32-bit and 64-bit PPLs once we confirm their stability; this would let us detect build
  drift without checking large binaries into git.

