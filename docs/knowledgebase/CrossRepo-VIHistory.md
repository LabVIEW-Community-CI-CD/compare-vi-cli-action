<!-- markdownlint-disable-next-line MD041 -->
# Cross-Repo VI History Capture

This note records the steps I took to exercise the Compare-VIHistory tooling
against an external repository (`LabVIEW-Community-CI-CD/labview-icon-editor`,
standing issue #527).

## Prerequisites

- Git history with the target VI available locally.
- LVCompare/LabVIEW installed (the same requirements as the action repo).
- Access to the Compare-VI tooling (`Compare-VIHistory.ps1`,
  `Compare-RefsToTemp.ps1`, and supporting modules).

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
   source ref/tag, source SHA, and the file closure for the bundle.

4. **Import the module from the extracted bundle**

   ```powershell
   Import-Module .\comparevi-tools\CompareVI.Tools-v<release-version>\tools\CompareVI.Tools\CompareVI.Tools.psd1 -Force
   ```

5. **Run the history helper**

   ```powershell
   Set-Location labview-icon-editor
   Invoke-CompareVIHistory `
     -TargetPath "Tooling/deployment/VIP_Post-Install Custom Action.vi" `
     -RenderReport `
     -FailOnDiff:$false `
     -InvokeScriptPath ..\comparevi-tools\CompareVI.Tools-v<release-version>\tools\Invoke-LVCompare.ps1
   ```

This path replaces whole-repository acquisition for module consumers while
keeping the integration pinned to a reviewed release tag.

## One-off local run from a source checkout (legacy / maintainer path)

1. **Clone the target repo**

   ```powershell
   git clone https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor.git
   ```

2. **Import the module**

   From the cloned `compare-vi-cli-action` repository run:

   ```powershell
   Import-Module (Join-Path $PWD 'tools/CompareVI.Tools/CompareVI.Tools.psd1') -Force
   ```

   The module exposes `Invoke-CompareVIHistory` and redirects all helper lookups
   back to this repository.

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

## Observations / gaps

- With `CompareVI.Tools` we can reuse `Compare-VIHistory` and
  `Compare-RefsToTemp` without copying scripts into the target repository.
- The published `CompareVI.Tools` zip bundle now covers the module acquisition
  path without cloning this repository.
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
