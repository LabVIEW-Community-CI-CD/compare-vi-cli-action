<!-- markdownlint-disable-next-line MD041 -->
# Cross-Repo VI History Capture

This note records the supported steps for exercising the Compare-VIHistory
tooling against an external repository. The pinned sample below uses
`svelderrainruiz/labview-icon-editor`, which is the active downstream icon
editor repository.

## Prerequisites

- Git history with the target VI available locally.
- LVCompare/LabVIEW installed (the same requirements as the action repo).
- Access to the Compare-VI tooling (`Compare-VIHistory.ps1`,
  `Compare-RefsToTemp.ps1`, and supporting modules).
- Hosted GitHub runner flows that use the bundle-backed NI Linux adapter also
  rely on `Run-NILinuxContainerCompare.ps1` plus its adjacent runtime support
  scripts from the same bundle.

## Preferred release-asset path

The release pipeline publishes an immutable `CompareVI.Tools` zip bundle on
each tagged release. For cross-repo usage, prefer downloading that asset
instead of checking out this repository.

Treat the backend release tag as the authoritative pin. The bundle's embedded
PowerShell manifest version is informative, but the supported consumer contract
is the reviewed release tag plus its published checksum/provenance.

1. **Download the pinned release asset**

   ```powershell
   $tag = 'v1.0.0'
   $asset = 'CompareVI.Tools-v<release-version>.zip'
   $uri = "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/releases/download/$tag/$asset"
   Invoke-WebRequest -Uri $uri -OutFile $asset
   ```

2. **Verify the archive**

   Download the matching `SHA256SUMS.txt` from the same release and confirm the
   hash for the zip before extracting it.

3. **Extract and inspect metadata**

   ```powershell
   Expand-Archive -Path .\CompareVI.Tools-v<release-version>.zip -DestinationPath .\comparevi-tools
   Get-Content .\comparevi-tools\CompareVI.Tools-v<release-version>\comparevi-tools-release.json
   ```

   The embedded metadata records the module version, repository source,
   source ref/tag, source SHA, the file closure for the bundle, and the
   supported downstream consumer contracts under
   `consumerContract.historyFacade` and
   `consumerContract.hostedNiLinuxRunner`.

4. **Import the module from the extracted bundle**

   ```powershell
   Import-Module .\comparevi-tools\CompareVI.Tools-v<release-version>\tools\CompareVI.Tools\CompareVI.Tools.psd1 -Force
   ```

5. **Run the facade helper**

   ```powershell
   Set-Location labview-icon-editor
   $history = Invoke-CompareVIHistoryFacade `
     -TargetPath "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi" `
     -Mode attributes,front-panel,block-diagram `
     -RenderReport `
     -FailOnDiff:$false `
     -InvokeScriptPath ..\comparevi-tools\CompareVI.Tools-v<release-version>\tools\Invoke-LVCompare.ps1

   $history.observedInterpretation.coverageClass
   $history.execution.requestedModes
   $history.execution.executedModes
   $history.reports.markdownPath
   ```

This path replaces whole-repository acquisition for module consumers while
keeping the integration pinned to a reviewed release tag. The returned facade
object is the supported downstream summary surface: requested/executed modes,
coverage and outcome interpretation, report paths, and per-mode tallies without
the raw backend comparison payloads.

For hosted GitHub runner diagnostics, use the same extracted bundle root as
`COMPAREVI_SCRIPTS_ROOT` and resolve the NI Linux runner from
`tools/Run-NILinuxContainerCompare.ps1`. Keep its adjacent support scripts
(`Assert-DockerRuntimeDeterminism.ps1` and
`Compare-ExitCodeClassifier.ps1`) in the extracted bundle; do not copy the
runner by itself.

## Pinned sample flow

Use this exact sample when you need a documented cross-repo consumer reference:

- Backend pin: reviewed `compare-vi-cli-action` release tag plus
  `comparevi-tools-release.json`
- Downstream repo: `svelderrainruiz/labview-icon-editor`
- Target VI:
  `resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi`
- Recommended modes: `attributes,front-panel,block-diagram`
- Supported module entry point: `Invoke-CompareVIHistoryFacade`
- Runtime summary artifact: `history-summary.json`

For reviewer-facing diagnostics surfaces, prefer explicit scoped modes instead
of aggregate lanes such as `default` or `full`. The bundle metadata now also
advertises `consumerContract.diagnosticsCommentRenderer.entryScriptPath =
tools/New-CompareVIHistoryDiagnosticsBody.ps1`, which comparevi-history
consumers can resolve from the extracted tooling root or workflow
`tooling-path` output instead of copying inline PowerShell comment renderers.

## One-off local run from a source checkout (legacy / maintainer path)

1. **Clone the target repo**

   ```powershell
   git clone https://github.com/svelderrainruiz/labview-icon-editor.git
   ```

2. **Import the module**

   From the cloned `compare-vi-cli-action` repository run:

   ```powershell
   Import-Module (Join-Path $PWD 'tools/CompareVI.Tools/CompareVI.Tools.psd1') -Force
   ```

   The module exposes both `Invoke-CompareVIHistory` and
   `Invoke-CompareVIHistoryFacade`, and redirects all helper lookups back to
   this repository.

3. **Run the history helper**

   ```powershell
   Set-Location labview-icon-editor
Invoke-CompareVIHistory `
  -TargetPath "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi" `
  -RenderReport `
  -FailOnDiff:$false `
  -InvokeScriptPath ..\compare-vi-cli-action\tools\Invoke-LVCompare.ps1
```
Add `-MaxPairs <n>` when you need to cap the number of commit pairs in the cross-repo run.

   - Outputs land in `tests/results/ref-compare/history/` inside the cloned
     repo (`history-report.md`, `history-report.html`, manifest JSON, etc.).
   - Works for any VI path with commit history; use `-StartRef` if you need to
     anchor to an older commit.
   - When LabVIEW is not available locally, point `-InvokeScriptPath` at a
     testing stub so the pipeline still emits manifests and reports.

### Reference fixtures

The repository ships a synthetic snapshot under
`fixtures/cross-repo/labview-icon-editor/settings-init/` (Markdown, HTML, and
JSON manifests). `tests/CompareVI.CrossRepo.Fixtures.Tests.ps1` validates that
the recorded metadata bucket counts (2 entries in the `metadata` bucket) stay
in sync with the documentation. Use the fixture as a template when capturing
new cross-repo runs.

## Offline corpus harness

For the seeded offline real-history corpus path added under issue `#894`, use
[`Offline-RealHistory-Corpus.md`](./Offline-RealHistory-Corpus.md). That flow
wraps `Compare-VIHistory` with the NI Windows container bridge and writes
generated evidence under `tests/results/offline-real-history/` instead of
committing bulky raw reports. Issue `#895` adds the deterministic committed
subset at `fixtures/real-history/offline-corpus.normalized.json`, which is
rebuilt from the checked-in seed fixture and tiny capture summaries instead of
from local run artifacts.

## Observations / gaps

- With `CompareVI.Tools` we can reuse `Compare-VIHistory` and
  `Compare-RefsToTemp` without copying scripts into the target repository.
- The published `CompareVI.Tools` zip bundle now covers the module acquisition
  path without cloning this repository.
- The bundle now also carries the hosted NI Linux runner surface needed by
  comparevi-history consumers that stage `nationalinstruments/labview:2026q1-linux`
  on hosted runners.
- A reusable workflow/facade is still useful for the cleanest `uses:` UX.

## Packaging decision (2025-10-31)

For issue #527 we will proceed with the **PowerShell module** approach:

- Create a module (working name `CompareVI.Tools`) that exports
  `Compare-VIHistory`, `Compare-RefsToTemp`, bucket metadata helpers, and the
  vendor resolver.
- Publish the module as part of the compare-vi-cli-action release process as a
  pinned zip bundle.
- Provide a simple wrapper script so GitHub workflows can import the module and
  invoke `Compare-VIHistory` without copying files.
- Generate a zip bundle from the release pipeline for consumers that prefer
  fixed artifacts.

## Next steps (tracked by issue #527)

- **Packaging options**  
  - *PowerShell module bundle*: publish `Compare-VIHistory`,
    `Compare-RefsToTemp`, bucket metadata, vendor resolvers, and compare
    engine dependencies as a self-contained `CompareVI.Tools` zip asset on each
    release. External repos download/unpack the bundle and import the module
    directly.  
  - *Reusable workflow/composite action*: wrap the helper in a GitHub Action
    that accepts repo+VI inputs and runs the history capture on a trusted
    runner.

- **Automation gaps to close**
  - Keep the release bundle metadata and verification guidance aligned with the
    published asset names.
  - Provide a sample workflow (e.g., `vi-history-cross-repo.yml`) that
    downloads the helper and runs it against a supplied repo/ref.
  - Clarify access requirements (SAML, LFS, large history impacts) in the docs.
  - Add validation that warns when the target VI has no history (e.g., history
    report shows only `_missing-base_` rows).
