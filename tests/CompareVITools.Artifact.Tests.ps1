Describe 'CompareVI.Tools artifact publishing' {
  BeforeAll {
    $candidateRoots = @()
    foreach ($candidate in @($PSScriptRoot, $PSCommandPath, (Get-Location).Path)) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }

      $resolved = $candidate
      if (Test-Path -LiteralPath $candidate) {
        $item = Get-Item -LiteralPath $candidate
        $resolved = if ($item.PSIsContainer) { $item.FullName } else { Split-Path -Parent $item.FullName }
      }
      $candidateRoots += $resolved
    }

    $repoRoot = $null
    foreach ($root in $candidateRoots | Select-Object -Unique) {
      $cursor = $root
      while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $marker = Join-Path $cursor 'tools' 'Publish-CompareVIToolsArtifact.ps1'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
          $repoRoot = $cursor
          break
        }

        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
          break
        }
        $cursor = $parent
      }

      if ($repoRoot) {
        break
      }
    }

    if (-not $repoRoot) {
      throw 'Unable to resolve repository root for CompareVI.Tools artifact tests.'
    }

    $publishScript = Join-Path $repoRoot 'tools' 'Publish-CompareVIToolsArtifact.ps1'
    $modulePath = Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1'
    $schemaScript = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'comparevi-tools-release-manifest-v1.schema.json'
    $moduleManifest = Import-PowerShellDataFile -LiteralPath $modulePath
    $moduleVersion = [string]$moduleManifest.ModuleVersion
  }

  It 'writes a self-contained release zip and metadata manifest' {
    $outDir = Join-Path $TestDrive 'artifacts'
    $metadataPath = Join-Path $TestDrive 'comparevi-tools-artifact.json'

    & $publishScript `
      -OutputRoot $outDir `
      -MetadataReportPath $metadataPath `
      -Repository 'owner/repo' `
      -SourceRef 'refs/tags/v9.9.9' `
      -SourceSha '0123456789abcdef0123456789abcdef01234567' `
      -ReleaseTag 'v9.9.9'

    Test-Path -LiteralPath $metadataPath | Should -BeTrue
    & $schemaScript -JsonPath $metadataPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadata.schema | Should -Be 'comparevi-tools-release-manifest@v1'
    $metadata.module.name | Should -Be 'CompareVI.Tools'
    $metadata.module.version | Should -Be $moduleVersion
    $metadata.source.repository | Should -Be 'owner/repo'
    $metadata.source.ref | Should -Be 'refs/tags/v9.9.9'
    $metadata.source.sha | Should -Be '0123456789abcdef0123456789abcdef01234567'
    $metadata.source.releaseTag | Should -Be 'v9.9.9'

    $archivePath = Join-Path $outDir $metadata.bundle.archiveName
    Test-Path -LiteralPath $archivePath | Should -BeTrue

    $extractRoot = Join-Path $TestDrive 'extracted'
    Expand-Archive -Path $archivePath -DestinationPath $extractRoot

    $bundleRoot = Join-Path $extractRoot $metadata.bundle.folder
    Test-Path -LiteralPath $bundleRoot | Should -BeTrue

    $expectedFiles = @(
      'comparevi-tools-release.json',
      'README.md',
      'tools/CompareVI.Tools/CompareVI.Tools.psd1',
      'tools/CompareVI.Tools/CompareVI.Tools.psm1',
      'tools/Compare-VIHistory.ps1',
      'tools/Compare-RefsToTemp.ps1',
      'tools/Invoke-LVCompare.ps1',
      'tools/Stage-CompareInputs.ps1',
      'tools/VendorTools.psm1',
      'tools/VICategoryBuckets.psm1',
      'scripts/CompareVI.psm1',
      'scripts/ArgTokenization.psm1'
    )
    foreach ($relativePath in $expectedFiles) {
      $candidate = Join-Path $bundleRoot $relativePath
      Test-Path -LiteralPath $candidate | Should -BeTrue
    }

    $archiveMetadataPath = Join-Path $bundleRoot 'comparevi-tools-release.json'
    $archiveMetadata = Get-Content -LiteralPath $archiveMetadataPath -Raw | ConvertFrom-Json
    $archiveMetadata.bundle.metadataPath | Should -Be 'comparevi-tools-release.json'
    $archiveMetadata.bundle.files.Count | Should -BeGreaterThan 5
  }

  It 'exports the bundle root through COMPAREVI_SCRIPTS_ROOT when invoking the module wrapper' {
    $bundleRoot = Join-Path $TestDrive 'bundle'
    $moduleRoot = Join-Path $bundleRoot 'tools' 'CompareVI.Tools'
    $toolsRoot = Join-Path $bundleRoot 'tools'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psd1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psm1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psm1')

    $capturePath = Join-Path $TestDrive 'scripts-root.txt'
    @'
param(
  [string]$TargetPath
)
Set-Content -LiteralPath $env:COMPAREVI_CAPTURE_PATH -Value $env:COMPAREVI_SCRIPTS_ROOT -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot 'Compare-VIHistory.ps1') -Encoding utf8

    $env:COMPAREVI_CAPTURE_PATH = $capturePath
    try {
      Import-Module (Join-Path $moduleRoot 'CompareVI.Tools.psd1') -Force
      Invoke-CompareVIHistory -TargetPath 'Dummy.vi'
    } finally {
      Remove-Module CompareVI.Tools -Force -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_CAPTURE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
    }

    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capturedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $capturedRoot | Should -Be $bundleRoot
  }
}
