Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-OfflineRealHistoryCorpus.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:HarnessScript = Join-Path $repoRoot 'tools' 'Invoke-OfflineRealHistoryCorpus.ps1'
    if (-not (Test-Path -LiteralPath $script:HarnessScript -PathType Leaf)) {
      throw "Invoke-OfflineRealHistoryCorpus.ps1 not found at $script:HarnessScript"
    }

    $script:CompareHistoryStub = @'
[CmdletBinding()]
param(
  [string]$TargetPath,
  [string]$StartRef = 'HEAD',
  [string]$EndRef,
  [string[]]$Mode = @('default'),
  [int]$MaxPairs = 1,
  [switch]$FailOnDiff,
  [switch]$RenderReport,
  [string]$ReportFormat = 'html',
  [string]$ResultsDir,
  [string]$InvokeScriptPath,
  [Nullable[int]]$CompareTimeoutSeconds
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ResultsDir) {
  throw 'ResultsDir is required.'
}
if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

$modeEntries = @()
foreach ($modeName in @($Mode)) {
  $slug = [string]$modeName
  $modeDir = Join-Path $ResultsDir $slug
  New-Item -ItemType Directory -Path $modeDir -Force | Out-Null
  $modeManifestPath = Join-Path $ResultsDir ("{0}-manifest.json" -f $slug)
  $modeManifest = [ordered]@{
    schema = 'vi-compare/history@v1'
    mode = $slug
    reportFormat = $ReportFormat
    flags = @()
    stats = [ordered]@{
      processed = 1
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      lastDiffIndex = 1
      lastDiffCommit = 'deadbeef'
      stopReason = 'max-pairs'
      errors = 0
      missing = 0
      categoryCounts = [ordered]@{ 'vi-attribute' = 1 }
      bucketCounts = [ordered]@{ metadata = 1 }
      collapsedNoise = [ordered]@{
        count = 0
        indices = @()
        commits = @()
        categoryCounts = [ordered]@{}
        bucketCounts = [ordered]@{}
      }
    }
    comparisons = @(
      [ordered]@{
        index = 1
        base = [ordered]@{ ref = 'base-ref' }
        head = [ordered]@{ ref = 'head-ref' }
      }
    )
    status = 'ok'
  }
  $modeManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $modeManifestPath -Encoding utf8
  $modeEntries += [ordered]@{
    name = $slug
    slug = $slug
    reportFormat = $ReportFormat
    flags = @()
    manifestPath = $modeManifestPath
    resultsDir = $modeDir
    stats = $modeManifest.stats
    status = 'ok'
  }
}

$artifactDir = Join-Path $ResultsDir 'default' 'pair-001-artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
([ordered]@{
  schema = 'lvcompare-capture-v1'
  exitCode = 1
  diff = $true
  cliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
} | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $artifactDir 'lvcompare-capture.json') -Encoding utf8
([ordered]@{
  schema = 'ni-windows-container-compare/v1'
  status = 'diff'
  exitCode = 1
  image = 'nationalinstruments/labview:2026q1-windows'
} | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $artifactDir 'ni-windows-container-capture.json') -Encoding utf8

$suiteManifest = [ordered]@{
  schema = 'vi-compare/history-suite@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  targetPath = $TargetPath
  requestedStartRef = $StartRef
  startRef = 'resolved-head'
  endRef = $EndRef
  maxPairs = $MaxPairs
  maxSignalPairs = 2
  noisePolicy = 'collapse'
  failFast = $false
  failOnDiff = [bool]$FailOnDiff
  reportFormat = $ReportFormat
  resultsDir = $ResultsDir
  requestedModes = @($Mode)
  executedModes = @($Mode)
  modes = @($modeEntries)
  stats = [ordered]@{
    modes = @($Mode).Count
    processed = @($Mode).Count
    diffs = @($Mode).Count
    signalDiffs = @($Mode).Count
    noiseCollapsed = 0
    errors = 0
    missing = 0
    categoryCounts = [ordered]@{ 'vi-attribute' = @($Mode).Count }
    bucketCounts = [ordered]@{ metadata = @($Mode).Count }
  }
  status = 'ok'
}
$suiteManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultsDir 'manifest.json') -Encoding utf8
'# History report' | Set-Content -LiteralPath (Join-Path $ResultsDir 'history-report.md') -Encoding utf8
'<html><body>History report</body></html>' | Set-Content -LiteralPath (Join-Path $ResultsDir 'history-report.html') -Encoding utf8
'@
  }

  It 'produces a plan-only envelope from the checked-in catalog' {
    $resultsRoot = Join-Path $TestDrive 'plan-results'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:HarnessScript `
      -PlanOnly `
      -RunId 'plan-contract' `
      -ResultsRoot $resultsRoot 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $runManifestPath = Join-Path $resultsRoot 'icon-editor-settings-init' 'plan-contract' 'offline-real-history-run.json'
    $runManifestPath | Should -Exist

    $manifest = Get-Content -LiteralPath $runManifestPath -Raw | ConvertFrom-Json -Depth 12
    $manifest.schema | Should -Be 'vi-history/offline-real-history-run@v1'
    $manifest.status | Should -Be 'planned'
    $manifest.planOnly | Should -BeTrue
    $manifest.target.id | Should -Be 'icon-editor-settings-init'
    @($manifest.target.requestedModes) | Should -Be @('default', 'attributes')
    $manifest.container.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $manifest.container.cliPath | Should -Be 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $manifest.storage.rawArtifactsInGit | Should -BeFalse
    @($manifest.target.executedModes).Count | Should -Be 0
  }

  It 'records executed modes and generated capture paths from a stub history run' {
    $harnessRoot = Join-Path $TestDrive 'stub-harness'
    $toolsDir = Join-Path $harnessRoot 'tools'
    $fixturesDir = Join-Path $harnessRoot 'fixtures' 'real-history'
    $externalRepoDir = Join-Path $harnessRoot 'external' 'labview-icon-editor'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $fixturesDir -Force | Out-Null
    New-Item -ItemType Directory -Path $externalRepoDir -Force | Out-Null

    Copy-Item -LiteralPath $script:HarnessScript -Destination (Join-Path $toolsDir 'Invoke-OfflineRealHistoryCorpus.ps1') -Force
    Set-Content -LiteralPath (Join-Path $toolsDir 'Invoke-NIWindowsContainerCompareBridge.ps1') -Value 'param()' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $toolsDir 'Compare-VIHistory.ps1') -Value $script:CompareHistoryStub -Encoding utf8

    $catalog = @'
{
  "$schema": "../../docs/schemas/offline-real-history-corpus-targets-v1.schema.json",
  "schema": "vi-history/offline-real-history-targets@v1",
  "generatedAt": "2026-03-08T00:00:00Z",
  "defaultWindowsImage": "nationalinstruments/labview:2026q1-windows",
  "defaultLabVIEWPath": "C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW.exe",
  "defaultCliPath": "C:\\Program Files\\National Instruments\\Shared\\LabVIEW CLI\\LabVIEWCLI.exe",
  "defaultComparePolicy": "cli-only",
  "storagePolicy": {
    "checkedInCatalogPath": "fixtures/real-history/offline-corpus.targets.json",
    "checkedInNormalizedPath": "fixtures/real-history/offline-corpus.normalized.json",
    "generatedRoot": "tests/results/offline-real-history",
    "rawArtifactsInGit": false
  },
  "targets": [
    {
      "id": "icon-editor-settings-init",
      "label": "labview-icon-editor Settings Init.vi",
      "repo": {
        "slug": "svelderrainruiz/labview-icon-editor",
        "localPathHints": [
          "external/labview-icon-editor"
        ],
        "startRef": "HEAD",
        "endRef": null
      },
      "seedFixture": {
        "historySuitePath": "fixtures/cross-repo/labview-icon-editor/settings-init/manifest.json"
      },
      "targetPath": "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi",
      "requestedModes": [
        "default",
        "attributes"
      ],
      "maxPairs": 3,
      "reportFormat": "html",
      "notes": [
        "stub target"
      ]
    }
  ]
}
'@
    Set-Content -LiteralPath (Join-Path $fixturesDir 'offline-corpus.targets.json') -Value $catalog -Encoding utf8

    $runOutput = & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Invoke-OfflineRealHistoryCorpus.ps1') `
      -CatalogPath 'fixtures/real-history/offline-corpus.targets.json' `
      -ResultsRoot 'tests/results/offline-real-history' `
      -RunId 'stub-run' `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $runManifestPath = Join-Path $harnessRoot 'tests' 'results' 'offline-real-history' 'icon-editor-settings-init' 'stub-run' 'offline-real-history-run.json'
    $runManifestPath | Should -Exist

    $manifest = Get-Content -LiteralPath $runManifestPath -Raw | ConvertFrom-Json -Depth 12
    $manifest.status | Should -Be 'captured'
    @($manifest.target.executedModes) | Should -Be @('default', 'attributes')
    $manifest.capture.historySuiteStatus | Should -Be 'ok'
    @($manifest.outputs.modeManifestPaths).Count | Should -Be 2
    @($manifest.outputs.lvcompareCapturePaths).Count | Should -Be 1
    @($manifest.outputs.niContainerCapturePaths).Count | Should -Be 1
    $manifest.outputs.aggregateManifestPath | Should -Match 'manifest\.json$'
    $manifest.outputs.historyReportMarkdownPath | Should -Match 'history-report\.md$'
    $manifest.outputs.historyReportHtmlPath | Should -Match 'history-report\.html$'
    $manifest.container.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
  }
}
