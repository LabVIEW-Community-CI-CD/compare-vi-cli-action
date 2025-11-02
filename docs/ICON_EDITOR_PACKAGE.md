# Icon Editor VI Package Audit

This note records what ships inside the committed fixture `tests/fixtures/icon-editor/ni_icon_editor-1.4.1.948.vip`
and how it maps back to sources in this repository or the upstream `ni/labview-icon-editor` project. Use it as a quick
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

The outer package (`ni_icon_editor`) contains the custom action VIs and a nested `ni_icon_editor_system` VIP that
carries the actual LabVIEW payload.

<!-- icon-editor-report:start -->
## Package layout highlights

- Fixture version `1.4.1.948` (system `1.4.1.948`), license `MIT`.
- Fixture path: `tests\fixtures\icon-editor\ni_icon_editor-1.4.1.948.vip`
- Package smoke status: **ok** (VIPs: 1)
- Report generated: `11/2/2025 1:28:33 PM`
- Artifacts:
  - ni_icon_editor-1.4.1.948.vip - 28.12 MB (`ed48a629e7fe5256dcb04cf3288a6e42fe8c8996dc33c4d838f8b102b43a9e44`)
  - ni_icon_editor_system-1.4.1.948.vip - 28.03 MB (`534ff97b24f608ac79997169eca9616ab2c72014cc9c9ea9955ee7fb3c5493c2`)
  - lv_icon_x64.lvlibp - 2.85 MB (`e851ac8d296e78f4ed1fd66af576c50ae5ff48caf18775ac3d4085c29d4bd013`)
  - lv_icon_x86.lvlibp - 2.85 MB (`8a3d07791c5f03d11bddfb32d25fd5d7c933a2950d96b5668cc5837fe7dece23`)

## Stakeholder summary

- Smoke status: **ok**
- Runner dependencies: match
- Custom actions: 4 entries (all match: True)
- Fixture-only assets discovered: 24

## Comparison with repository sources

- Custom action hashes:
| Action | Fixture Hash | Repo Hash | Match |
| --- | --- | --- | --- |
| VIP_Pre-Install Custom Action 2021.vi | `05ddb5a2995124712e31651ed4a623e0e43044435ff7af62c24a65fbe2a5273a` | `05ddb5a2995124712e31651ed4a623e0e43044435ff7af62c24a65fbe2a5273a` | match |
| VIP_Post-Install Custom Action 2021.vi | `29b4aec05c38707975a4d6447daab8eea6c59fcf0cde45f899f8807b11cd475e` | `29b4aec05c38707975a4d6447daab8eea6c59fcf0cde45f899f8807b11cd475e` | match |
| VIP_Pre-Uninstall Custom Action 2021.vi | `a10234da4dfe23b87f6e7a25f3f74ae30751193928d5700a628593f1120a5a91` | `a10234da4dfe23b87f6e7a25f3f74ae30751193928d5700a628593f1120a5a91` | match |
| VIP_Post-Uninstall Custom Action 2021.vi | `958b253a321fec8e65805195b1e52cda2fd509823d0ad18b29ae341513d4615b` | `958b253a321fec8e65805195b1e52cda2fd509823d0ad18b29ae341513d4615b` | match |

- Runner dependencies hash match: match

## Fixture-only assets

- script (1 entries)
  - update_readme_hours.py (7f5bbfadb1193a89f1a4aa6332ccf62650951d389edb2188d86e1e29442049c4)
- test (23 entries)
  - Unit Tests\Editor Position\Adjust Position.vi (7b14873d4a25688c5f78c40ffa547b93836a04661fbeeeddb426268fcd192dbb)
  - Unit Tests\Editor Position\Assert Windows Bounds.vi (8eb3bdbc13edaa58df1d3f9ad8d005c24cdae6ee2178bc9b099dc9781e69d7ca)
  - Unit Tests\Editor Position\Backup INI Data.vi (da527567a1c21e2c3bb89c28e315ae22ae4202323d28f4bc302ca56113a7e48b)
  - Unit Tests\Editor Position\Editor Position.lvclass (58ea81ddcd56be9a0aaa74a50684270d0c6c624fbde9ab538416ed87ae7321d8)
  - Unit Tests\Editor Position\INI Position Removed.vi (62872f3cc37348238d71d3c5ecb64bc7f0d93e62a3ec0e24b3137f9d6a5b391d)
  - ... 18 more

## Simulation metadata

- Simulation enabled: True
- Unit tests executed: False
<!-- icon-editor-report:end -->

## Follow-up opportunities

- Decide whether key assets that only live inside the package (e.g., `update_readme_hours.py`, unit-test directories)
  should be mirrored under `vendor/icon-editor/` for easier diffing, or if documenting their presence is sufficient.
- Capture golden hashes for the 32-bit and 64-bit PPLs once we confirm their stability; this would let us detect build
  drift without checking large binaries into git.
- Extend the simulation helper to emit a lightweight manifest of fixture-only scripts/tests so we can track upstream
  changes without unpacking the VIP manually.

## Maintaining this report

- Run `pwsh -File tools/icon-editor/Update-IconEditorFixtureReport.ps1` to regenerate the JSON summary and refresh the section above. The script runs automatically in the pre-push checks and fails when the committed doc is stale.
- The generated summary lives at `tests/results/_agent/icon-editor/fixture-report.json`; delete it if you need a clean slate.
- Canonical hashes are enforced by `node --test tools/icon-editor/__tests__/fixture-hashes.test.mjs` (invoked from `tools/PrePush-Checks.ps1`), so report drift from the committed fixture is caught automatically.
- Validate uploads the `icon-editor-fixture-report` artifact (JSON + Markdown) so stakeholders can review the latest snapshot without digging through logs.

