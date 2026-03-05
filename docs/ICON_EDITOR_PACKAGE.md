# Icon Editor VI Package Audit

> Scope update (March 5, 2026): icon editor development moved to
> `svelderrainruiz/labview-icon-editor`. This document is retained as historical
> reference and is not part of current standing-priority scope in this repository.

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
- Package smoke status: **fail** (VIPs: 1)
- Report generated: `11/4/2025 2:11:28 PM`
- Artifacts:
  - ni_icon_editor-1.4.1.948.vip - 0.35 MB (`919104d1e35405e40862776f853cc6b9c23b87121d4b717fcbd06742e937e75e`)
  - ni_icon_editor_system-1.4.1.948.vip - 0.28 MB (`8181b37939ed27faa0fdf5f87c881e1cc0b2fe4edecee4384a10c04b9b9af03a`)
  - lv_icon_x64.lvlibp - 2.85 MB (`e851ac8d296e78f4ed1fd66af576c50ae5ff48caf18775ac3d4085c29d4bd013`)
  - lv_icon_x86.lvlibp - 2.85 MB (`8a3d07791c5f03d11bddfb32d25fd5d7c933a2950d96b5668cc5837fe7dece23`)

## Stakeholder summary

- Smoke status: **fail**
- Runner dependencies: mismatch
- Custom actions: 4 entries (all match: False)
- Fixture-only assets discovered: 311

## Comparison with repository sources

- Custom action hashes:
| Action | Fixture Hash | Repo Hash | Match |
| --- | --- | --- | --- |
| VIP_Pre-Install Custom Action 2021.vi | `_missing_` | `_missing_` | mismatch |
| VIP_Post-Install Custom Action 2021.vi | `_missing_` | `_missing_` | mismatch |
| VIP_Pre-Uninstall Custom Action 2021.vi | `_missing_` | `_missing_` | mismatch |
| VIP_Post-Uninstall Custom Action 2021.vi | `_missing_` | `_missing_` | mismatch |

- Runner dependencies hash match: mismatch

## Fixture-only assets

- resource (311 entries)
  - plugins\lv_icon.vi (af6be82644d7b0d9252bb5188847a161c641653a38f664bddcacc75bbc6b0b51)
  - plugins\lv_icon.vit (c74159e8f4e16d1881359dae205e71fdee6131020c7c735440697138eec0c0dd)
  - plugins\lv_IconEditor.lvlib (a2721f0b8aea3c32a00d0b148f24bdeee05201b41cffbaa212dbe325fdd4f3f7)
  - plugins\NIIconEditor\Class\Ants\Ants.lvclass (650baef4cded7115e549f0f99258884c43185f88b6a082b1629e0fa72406f176)
  - plugins\NIIconEditor\Class\Ants\GET\GET_AntsLine.vi (794dfcbf2ed7ff560f2346ba51c840d00dc22e58098c9f4a76cdeb370b9c9df9)
  - ... 306 more

## Fixture-only manifest delta

- Added: 311, Removed: 311, Changed: 0
- Added:
  - `resource:tests\plugins\niiconeditor\class\fakedarray\misc\updatevisibledata.vi`
  - `resource:tests\plugins\niiconeditor\controls\draw.ctl`
  - `resource:tests\plugins\niiconeditor\controls\user event communication enum.ctl`
  - `resource:tests\plugins\niiconeditor\miscellaneous\icon editor\mousemove.vi`
  - `resource:tests\plugins\lv_icon.vit`
  - (+306 more)
- Removed:
  - `resource:resource\plugins\lv_icon.vi`
  - `resource:resource\plugins\lv_icon.vit`
  - `resource:resource\plugins\lv_iconeditor.lvlib`
  - `resource:resource\plugins\niiconeditor\class\ants\ants.lvclass`
  - `resource:resource\plugins\niiconeditor\class\ants\get\get_antsline.vi`
  - (+306 more)

## Changed VI comparison (requests)

- When changed VI assets are detected, Validate publishes an 'icon-editor-fixture-vi-diff-requests' artifact
  with the list of base/head paths for LVCompare.
- Local runs can generate requests via tools/icon-editor/Prepare-FixtureViDiffs.ps1.

## Simulation metadata

- Simulation enabled: True
- Unit tests executed: False
<!-- icon-editor-report:end -->

## Development mode targets

- LabVIEW targets are now managed in `configs/icon-editor/dev-mode-targets.json` (schema `icon-editor/dev-mode-targets@v1`). Each operation maps to the LabVIEW version/bitness it needs; the defaults ship with:
  - `BuildPackage` → LabVIEW 2021 (32-bit and 64-bit) for VIP builds.
  - `Compare` → LabVIEW 2025 (64-bit) for VI comparison/report helpers.
- `Enable-IconEditorDevelopmentMode` and `Disable-IconEditorDevelopmentMode` accept an `-Operation` switch so callers do not have to repeat version/bitness lists. Examples:

  ```powershell
  # Prep the icon editor repository for VI comparisons (LabVIEW 2025 x64)
  pwsh -File tools/icon-editor/Enable-DevMode.ps1 `
    -RepoRoot . `
    -IconEditorRoot vendor/icon-editor `
    -Operation Compare

  # ... run comparisons ...

  pwsh -File tools/icon-editor/Disable-DevMode.ps1 `
    -RepoRoot . `
    -IconEditorRoot vendor/icon-editor `
    -Operation Compare

  # Enable development mode for packaging/build flows (LabVIEW 2021 32/64)
  pwsh -File tools/icon-editor/Enable-DevMode.ps1 `
    -RepoRoot . `
    -IconEditorRoot vendor/icon-editor `
    -Operation BuildPackage
  ```

- You can still override `-Versions`/`-Bitness` explicitly when experimenting; doing so bypasses the policy file for that invocation.

## Follow-up opportunities

- Decide whether key assets that only live inside the package (e.g., `update_readme_hours.py`, unit-test directories)
  should be mirrored under `vendor/icon-editor/` for easier diffing, or if documenting their presence is sufficient.
- Capture golden hashes for the 32-bit and 64-bit PPLs once we confirm their stability; this would let us detect build
  drift without checking large binaries into git.
- Extend the simulation helper to emit a lightweight manifest of fixture-only scripts/tests so we can track upstream
  changes without unpacking the VIP manually.
- A secondary fixture (`tests\fixtures\icon-editor\ni_icon_editor-1.4.1.794.vip`) plus manifest
  (`tests\fixtures\icon-editor\fixture-manifest-1.4.1.794.json`) exists for automated baseline comparisons.

## Local validate helper (self-hosted)

- Script: `tools/icon-editor/Invoke-ValidateLocal.ps1`
- Purpose: replicate the icon-editor jobs from Validate on the self-hosted runner without waiting for GitHub Actions.
- Requirements:
  - Run on the self-hosted Windows machine with LabVIEW/LVCompare + TestStand harness configured (same tooling as CI).
  - Provide `GH_TOKEN`/`GITHUB_TOKEN` so priority sync and policy checks succeed.
  - Baseline fixtures live under `tests/fixtures/icon-editor/`.
- Usage:

  ```powershell
  # Full run (LVCompare enabled)
  pwsh -File tools/icon-editor/Invoke-ValidateLocal.ps1

  # Dry run without launching LVCompare
  pwsh -File tools/icon-editor/Invoke-ValidateLocal.ps1 -SkipLVCompare

  # Override baseline VIP
  pwsh -File tools/icon-editor/Invoke-ValidateLocal.ps1 `
    -BaselineFixture 'D:\vip\ni_icon_editor-1.4.1.700.vip' `
    -BaselineManifest 'D:\vip\fixture-manifest-1.4.1.700.json'

  # Run via npm helper (dry-run)
  node tools/npm/run-script.mjs icon-editor:validate -- --DryRun --SkipBootstrap --SkipLVCompare
  ```

- Outputs land in `tests/results/_agent/icon-editor/local-validate` by default:
  - `fixture-report.json` / `manifest.json`
  - `vi-diff/vi-diff-requests.json`
  - `vi-diff-captures/**` + `vi-comparison-report.md`
  - (optional) `vip-vi-diff*` when `-IncludeSimulation` is supplied
  - Pester / PrePush outputs (standard locations under `tests/results`)

- Flags:
  - `-SkipBootstrap` skips `priority/bootstrap.ps1` when you already ran it.
  - `-SkipLVCompare` or `-DryRun` keeps the compare tooling in dry-run mode.
  - `-ResultsRoot` customizes the output directory.
  - `-KeepWorkspace` retains extraction folders for debugging.
  - `-IncludeSimulation` runs the simulation VIP diff path (dry-run comparisons).

## Syncing a fork for diff coverage

- Script: `tools/icon-editor/Sync-IconEditorFork.ps1`
- Purpose: clone a forked `labview-icon-editor` repository (default remote `icon-editor`), mirror it into `vendor/icon-editor/`, and optionally kick off fixture updates or the local Validate helper.
- Usage:

  ```powershell
  # Sync using configured remote "icon-editor" (branch develop)
  pwsh -File tools/icon-editor/Sync-IconEditorFork.ps1

  # Sync a specific slug + update fixture report + run local validate
  pwsh -File tools/icon-editor/Sync-IconEditorFork.ps1 `
    -RepoSlug 'your-org/labview-icon-editor' `
    -UpdateFixture `
    -RunValidateLocal `
    -SkipBootstrap
  ```

- Assumptions:
  - Remote `icon-editor` is configured (`git remote add icon-editor ...`). Pass `-RepoSlug owner/repo` if you prefer direct slugs.
  - Branch defaults to `develop`; override via `-Branch`.
  - Use `-WorkingPath <path>` to mirror the fork into a disposable workspace instead of `vendor/icon-editor/` (handy for staging synthetic heads).
- Sync uses `robocopy /MIR`; review changes under `vendor/icon-editor/` before committing.
- Use `-UpdateFixture` to regenerate `fixture-report.json` / `fixture-manifest.json`, then run `Invoke-ValidateLocal` or dispatch CI to produce VI comparison reports.

### VI comparison report artifacts

- Validate publishes the report when the `icon-editor-compare` job runs on the self-hosted Windows pool. Enable the job by setting the repo variable `ICON_EDITOR_COMPARE_ENABLE=1`, or queue a one-off dispatch with `enable_compare=1`.
- The job emits two artifacts whenever `vi-diff-requests.json` contains entries:
  - `icon-editor-vi-diff-captures` – per-VI capture directories, including `compare/lvcompare-capture.json` and raw LVCompare assets.
  - `icon-editor-vi-comparison-report` – Markdown + JSON summary (`vi-comparison-report.md` / `.json`) linking back to the captures.
- Download the latest report from CI:

  ```powershell
  $run    = gh run list --repo $Env:GITHUB_REPOSITORY --workflow Validate --json databaseId,conclusion \
             | ConvertFrom-Json | Where-Object conclusion -eq 'success' | Select-Object -First 1
  gh run download $run.databaseId --repo $Env:GITHUB_REPOSITORY `
    --name icon-editor-vi-comparison-report --dir artifacts/icon-editor/report
  ```

  The Markdown file includes a status table (same/different/error) and links back to the capture artifact.

## Building overlays from icon-editor commits

- Script: `tools/icon-editor/Prepare-OverlayFromRepo.ps1`
- Purpose: diff two refs inside an icon-editor repository and copy only the changed resource/test VIs into a clean overlay directory.
- Usage:

  ```powershell
  $repo    = 'tmp/icon-editor/repo'   # git clone of labview-icon-editor
  $overlay = 'tmp/icon-editor/overlay'
  $baseRef = 'e293e7335870e33c5c33ed2e5052f8edf504c5a0^'
  $headRef = 'e293e7335870e33c5c33ed2e5052f8edf504c5a0'

  pwsh -File tools/icon-editor/Prepare-OverlayFromRepo.ps1 `
    -RepoPath $repo `
    -BaseRef $baseRef `
    -HeadRef $headRef `
    -OverlayRoot $overlay `
    -Force
  ```

- The overlay is ready to feed into `Stage-IconEditorSnapshot.ps1` or `Invoke-IconEditorSnapshotFromRepo.ps1` so only the changed VIs are queued for LVCompare.

## Staging synthetic head snapshots (fake PRs)

- Script: `tools/icon-editor/Stage-IconEditorSnapshot.ps1`
- Purpose: reuse an existing checkout (or an overlay generated by `Prepare-OverlayFromRepo.ps1`) inside an isolated workspace, regenerate the head manifest/report on top of the committed VIP fixture, and optionally run `Invoke-ValidateLocal.ps1` to produce VI comparison requests/captures.
- Usage:

  ```powershell
  # Refresh manifest + report only
  pwsh -File tools/icon-editor/Stage-IconEditorSnapshot.ps1 `
    -SourcePath vendor/icon-editor `
    -WorkspaceRoot tmp/icon-editor/snapshots `
    -StageName 'local-head' `
    -SkipValidate

  # Stage overlay results and run validate in dry-run mode
  pwsh -File tools/icon-editor/Stage-IconEditorSnapshot.ps1 `
    -SourcePath tmp/icon-editor/repo `
    -ResourceOverlayRoot tmp/icon-editor/overlay `
    -WorkspaceRoot tests/results/_agent/icon-editor/snapshots `
    -StageName 'auto-proof' `
    -DryRun `
    -SkipBootstrapForValidate
  ```

- For a single command that prepares the overlay, stages the snapshot, and (optionally) runs Validate, use `tools/icon-editor/Invoke-IconEditorSnapshotFromRepo.ps1`:

  ```powershell
  pwsh -File tools/icon-editor/Invoke-IconEditorSnapshotFromRepo.ps1 `
    -RepoPath tmp/icon-editor/repo `
    -BaseRef main~1 `
    -HeadRef main `
    -WorkspaceRoot tests/results/_agent/icon-editor/snapshots `
    -StageName 'auto-proof' `
    -DryRun
  ```

- Outputs (under `tests/results/_agent/icon-editor/snapshots/<stage>/` by default):
  - `head-manifest.json` — synthetic `icon-editor/fixture-manifest@v1` for the staged overlay
  - `report/fixture-report.json` — the refreshed fixture report (rendered by `Update-IconEditorFixtureReport.ps1`)
  - `validate/**` — results from `Invoke-ValidateLocal` (when not skipped), including VI diff requests/captures and comparison report
- Flags:
  - `-SourcePath` reuses an existing tree. Pair it with `Prepare-OverlayFromRepo.ps1` to limit the snapshot to just the changed resources/tests.
  - `-SkipValidate` prevents `Invoke-ValidateLocal` from running; the helper still emits the manifest/report.
  - `-DryRun` automatically sets `-SkipLVCompare` for the validate step so LVCompare stays offline.
  - `-DevModeVersions` / `-DevModeBitness` let you override the LabVIEW version/bitness used when toggling development mode (defaults to 2025 / 64-bit). Use `-SkipDevMode` to bypass the toggle entirely if you have already prepared the environment.
  - When not specified, the helper inspects the local LabVIEW installations via `Get-IconEditorDevModeLabVIEWTargets` and prefers LabVIEW 2025 x64 when present, falling back to any available LabVIEW 2025 bitness (or the newest detected version).
  - `-SkipBootstrapForValidate` passes through to `Invoke-ValidateLocal` when `priority/bootstrap.ps1` already ran.
- Pair with `Sync-IconEditorFork.ps1` when you want a long-lived mirror under `vendor/icon-editor/`, or use this helper to stage ad-hoc “fake PR” heads before pushing upstream.
- For quick diffs without editing the VI in LabVIEW, mirror the resource tree into a disposable overlay, swap in a substitute VI, then stage the snapshot:

  ```powershell
  $overlay = 'tmp/icon-editor/overlay'
  robocopy vendor/icon-editor/resource $overlay /MIR

  Remove-Item (Join-Path $overlay 'plugins\NIIconEditor\Miscellaneous\User Events\Initialization_UserEvents.vi')
  Copy-Item (Join-Path $overlay 'plugins\NIIconEditor\Support\ApplyLibIconOverlayToVIIcon.vi') `
           (Join-Path $overlay 'plugins\NIIconEditor\Miscellaneous\User Events\Initialization_UserEvents.vi')

  pwsh -File tools/icon-editor/Stage-IconEditorSnapshot.ps1 `
    -SourcePath vendor/icon-editor `
    -ResourceOverlayRoot $overlay `
    -WorkspaceRoot tests/results/_agent/icon-editor/snapshots `
    -StageName 'vi-diff-proof' `
    -SkipValidate
  ```

  After the run, rebuild the overlay from `vendor/icon-editor/resource` (or restore the original VI) so the next snapshot starts from a clean baseline.
### Heuristic VI diff sweep (Issue #583)

- Script: `tools/icon-editor/Invoke-VIDiffSweepStrong.ps1`
- Purpose: triage a range of icon-editor commits, skipping LVCompare for VIs that are pure renames or whose blobs are unchanged. Only the remaining “interesting” VIs are passed to `Invoke-VIComparisonFromCommit.ps1`, which still uses raw paths so dependencies stay intact.
- Quick triage (heuristics only; no LVCompare launches):

  ```powershell
  pwsh -File tools/icon-editor/Invoke-VIDiffSweepStrong.ps1 `
    -RepoPath tmp/icon-editor/repo `
    -BaseRef origin/develop~20 `
    -HeadRef origin/develop `
    -Mode quick `
    -CachePath tests/results/_agent/icon-editor/vi-diff-cache.json `
    -EventsPath tests/results/_agent/icon-editor/vi-diff/compare-events.ndjson `
    -SummaryPath tests/results/_agent/icon-editor/vi-diff-summary.json `
    -Quiet
  ```

- Full sweep (default; launches LVCompare when heuristics say “compare”):

  ```powershell
  pwsh -File tools/icon-editor/Invoke-VIDiffSweepStrong.ps1 `
    -RepoPath tmp/icon-editor/repo `
    -BaseRef origin/develop~20 `
    -HeadRef origin/develop `
    -WorkspaceRoot tests/results/_agent/icon-editor/snapshots `
    -CachePath tests/results/_agent/icon-editor/vi-diff-cache.json `
    -EventsPath tests/results/_agent/icon-editor/vi-diff/compare-events.ndjson `
    -SummaryPath tests/results/_agent/icon-editor/vi-diff-summary.json `
    -Quiet
  ```

  Remove `-Mode quick` (or pass `-Mode full`) to run the full path. Delete the cache file if you need to force fresh decisions.

- Flags roll up to the underlying helpers:
  - `-SkipValidate`, `-SkipLVCompare` → forwarded to `Invoke-VIComparisonFromCommit.ps1` when comparisons still run.
  - `-LabVIEWExePath` → overrides the auto-resolved LabVIEW 2025 64-bit binary.
- `-EventsPath` controls where heuristic decisions are logged (`compare-events.ndjson` style). Omit to use the default under `tests/results/_agent/icon-editor/vi-diff/`.
- `-CachePath` stores per-commit decisions so re-running the sweep can fast-path previously triaged commits.
- Heuristic tuning (size delta threshold, compare throttling, prefix allow/deny rules) lives in `configs/icon-editor/vi-diff-heuristics.json`. Set `ICON_EDITOR_VI_DIFF_RULES` to point at an alternate JSON file while experimenting locally. `maxComparePerCommit` limits how many VI paths a single commit can send to LVCompare; overflow paths are skipped with a `compare-throttle` reason so you can follow up manually.
- Summary output structure (also written to `-SummaryPath` when provided):

  ```json
  {
    "repoPath": "tmp/icon-editor/repo",
    "baseRef": "origin/develop~20",
    "headRef": "origin/develop",
    "totalCommits": 5,
    "commits": [
      {
        "commit": "4de1aeae…",
        "comparePaths": [],
        "skipped": [
          { "path": "resource/plugins/…/MenuSelection(User).vi", "reason": "rename without content change" }
        ]
      },
      {
        "commit": "ec1d4952…",
        "comparePaths": [ "resource/plugins/…/Export_Clipboard.vi" ],
        "skipped": []
      }
    ]
  }
  ```

  Use `-StageNamePrefix` (default `commit`) to control the directory naming inside `tests/results/_agent/icon-editor/snapshots`.

## Maintaining this report

- Run `pwsh -File tools/icon-editor/Update-IconEditorFixtureReport.ps1` to regenerate the JSON summary and refresh the section above. The script runs automatically in the pre-push checks and fails when the committed doc is stale.
- The generated summary lives at `tests/results/_agent/icon-editor/fixture-report.json`; delete it if you need a clean slate.
- Canonical hashes are enforced by `node --test tools/icon-editor/__tests__/fixture-hashes.test.mjs` (invoked from `tools/PrePush-Checks.ps1`), so report drift from the committed fixture is caught automatically.
- Validate uploads the `icon-editor-fixture-report` artifact (JSON + Markdown) so stakeholders can review the latest snapshot without digging through logs.

## Local replay for CI build failures

When a historical `Build VI Package` job fails in the legacy
`ci-composite.yml` workflow, you can replay that stage locally without
re-running the full legacy pipeline:

```powershell
pwsh tools/icon-editor/Replay-BuildVipJob.ps1 -RunId <workflow-run-id>
```

The helper:

1. Downloads the job log via `gh`, extracts the display-information payload, and
   (optionally) fetches the packaged `lv_icon_*.lvlibp` artifacts.
2. Regenerates release notes and updates the VIPB metadata with the new PowerShell
   helper.
3. Rebuilds the VI package via `Invoke-IconEditorVipBuild` (g-cli toolchain by
   default) so the replay path matches the CI job.

Pass `-LogPath path\to\log.txt` when you already have the log, and `-DownloadArtifacts`
to pull the upstream PPLs automatically before the build.

To experiment with alternate backends, supply `-BuildToolchain vipm` to route the
package step through the VIPM provider, or pass `-BuildProvider <name>` to request a
specific provider registration (for example, a custom g-cli shim). The summary emitted
by the script now records both the toolchain and resolved provider so you can confirm
which backend executed the build. The generated `icon-editor/build@v1` manifest records
the requested backend under `packaging.requestedToolchain` (and `packaging.requestedProvider`
when supplied) so downstream diagnostics stay transparent.

When dependency application is the failing stage, replay it via:

```powershell
pwsh tools/icon-editor/Replay-ApplyVipcJob.ps1 -RunId <workflow-run-id> -JobName 'Apply VIPC Dependencies (2025, 64)'
```

The script resolves the LabVIEW version/bitness from the matrix entry (or accepts them
explicitly), reruns `.github/actions/apply-vipc/ApplyVIPC.ps1` using the VIPM provider,
and surfaces the same telemetry locally so you can investigate VIPM prompts or missing
paths without re-queuing a self-hosted runner. Pass `-SkipExecution` to inspect the
replay command without running it, or reuse `-LogPath` when you already downloaded the
job log (`gh run view … --log`).
