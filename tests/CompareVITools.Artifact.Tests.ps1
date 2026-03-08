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
    $modulePrerelease = if ($moduleManifest.ContainsKey('PrivateData') -and $moduleManifest.PrivateData.PSData.ContainsKey('Prerelease')) {
      [string]$moduleManifest.PrivateData.PSData.Prerelease
    } else {
      ''
    }
    $moduleReleaseVersion = if ([string]::IsNullOrWhiteSpace($modulePrerelease)) {
      $moduleVersion
    } else {
      "$moduleVersion-$modulePrerelease"
    }
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
    $metadata.module.releaseVersion | Should -Be $moduleReleaseVersion
    @($metadata.module.exportedFunctions) | Should -Contain 'Invoke-CompareVIHistoryFacade'
    $metadata.source.repository | Should -Be 'owner/repo'
    $metadata.source.ref | Should -Be 'refs/tags/v9.9.9'
    $metadata.source.sha | Should -Be '0123456789abcdef0123456789abcdef01234567'
    $metadata.source.releaseTag | Should -Be 'v9.9.9'
    $metadata.consumerContract.historyFacade.schema | Should -Be 'comparevi-tools/history-facade@v1'
    $metadata.consumerContract.historyFacade.exportedFunction | Should -Be 'Invoke-CompareVIHistoryFacade'
    $metadata.consumerContract.historyFacade.resultsRelativePath | Should -Be 'history-summary.json'

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
      'tools/Render-VIHistoryReport.ps1',
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

  It 'returns the stabilized history facade when invoking the module facade wrapper' {
    $bundleRoot = Join-Path $TestDrive 'bundle-facade'
    $moduleRoot = Join-Path $bundleRoot 'tools' 'CompareVI.Tools'
    $toolsRoot = Join-Path $bundleRoot 'tools'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psd1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psm1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psm1')

    $capturePath = Join-Path $TestDrive 'facade-scripts-root.txt'
    @'
param(
  [string]$TargetPath,
  [string[]]$Mode = @('default'),
  [string]$ResultsDir = 'tests/results/ref-compare/history',
  [string]$GitHubOutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $env:COMPAREVI_CAPTURE_PATH -Value $env:COMPAREVI_SCRIPTS_ROOT -Encoding utf8
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$resolvedResultsDir = (Resolve-Path -LiteralPath $ResultsDir).Path
$summaryPath = Join-Path $resolvedResultsDir 'history-summary.json'
$summary = [ordered]@{
  schema = 'comparevi-tools/history-facade@v1'
  generatedAtUtc = '2026-03-08T00:00:00Z'
  target = [ordered]@{
    path = $TargetPath
    requestedStartRef = 'HEAD'
    effectiveStartRef = 'HEAD'
  }
  execution = [ordered]@{
    status = 'ok'
    reportFormat = 'html'
    resultsDir = $resolvedResultsDir
    manifestPath = (Join-Path $resolvedResultsDir 'manifest.json')
    requestedModes = @('default', 'attributes')
    executedModes = @('default')
  }
  observedInterpretation = [ordered]@{
    coverageClass = 'catalog-partial'
    coverageDetail = 'requested: 2; executed: 1; missing: attributes'
    modeSensitivity = 'single-mode-observed'
    outcomeLabels = @('clean', 'signal-diff')
  }
  summary = [ordered]@{
    modes = 1
    comparisons = 2
    diffs = 1
    signalDiffs = 1
    noiseCollapsed = 0
    missing = 0
    errors = 0
    categories = @('VI Attribute')
    bucketProfile = @('metadata')
    categoryCountKeys = @('vi-attribute')
    bucketCountKeys = @('metadata')
  }
  reports = [ordered]@{
    markdownPath = (Join-Path $resolvedResultsDir 'history-report.md')
    htmlPath = (Join-Path $resolvedResultsDir 'history-report.html')
  }
  modes = @(
    [ordered]@{
      name = 'default'
      slug = 'default'
      status = 'ok'
      processed = 2
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      missing = 0
      errors = 0
      categories = @('VI Attribute')
      bucketProfile = @('metadata')
      flags = @('-nobd')
      manifestPath = (Join-Path $resolvedResultsDir 'default' 'manifest.json')
      resultsDir = (Join-Path $resolvedResultsDir 'default')
    }
  )
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if ($GitHubOutputPath) {
  "history-summary-json=$summaryPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot 'Compare-VIHistory.ps1') -Encoding utf8

    $env:COMPAREVI_CAPTURE_PATH = $capturePath
    try {
      Import-Module (Join-Path $moduleRoot 'CompareVI.Tools.psd1') -Force
      $result = Invoke-CompareVIHistoryFacade -TargetPath 'Dummy.vi' -ResultsDir (Join-Path $TestDrive 'facade-results')
    } finally {
      Remove-Module CompareVI.Tools -Force -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_CAPTURE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
    }

    $result | Should -Not -BeNullOrEmpty
    $result.schema | Should -Be 'comparevi-tools/history-facade@v1'
    @($result.execution.requestedModes) | Should -Be @('default', 'attributes')
    @($result.execution.executedModes) | Should -Be @('default')
    $result.observedInterpretation.coverageClass | Should -Be 'catalog-partial'
    @($result.observedInterpretation.outcomeLabels) | Should -Be @('clean', 'signal-diff')
    @($result.modes | ForEach-Object { [string]$_.slug }) | Should -Be @('default')

    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capturedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $capturedRoot | Should -Be $bundleRoot
  }
}
