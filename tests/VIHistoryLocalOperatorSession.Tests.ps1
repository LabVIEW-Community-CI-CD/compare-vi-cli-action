Describe 'VI history local operator session' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $sessionScript = Join-Path $repoRoot 'tools' 'Invoke-VIHistoryLocalOperatorSession.ps1'
    $schemaScript = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'comparevi-local-operator-session-v1.schema.json'
  }

  It 'writes a session manifest that wraps the local refinement receipt without a review hook' {
    $repoUnderTest = Join-Path $TestDrive 'repo'
    $resultsRoot = Join-Path $repoUnderTest 'tests/results/local-vi-history/dev-fast'
    $refinementScript = Join-Path $TestDrive 'Invoke-VIHistoryLocalRefinement.stub.ps1'
    New-Item -ItemType Directory -Path (Join-Path $repoUnderTest 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    @'
param(
  [string]$Profile = 'dev-fast',
  [string]$RepoRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { (Get-Location).Path } else { $RepoRoot }
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/dev-fast'
} else {
  $ResultsRoot
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  image = 'comparevi-vi-history-dev:local'
  toolSource = 'local-dev-image'
  cacheReuseState = 'existing-local-image'
  coldWarmClass = 'warm'
  benchmarkSampleKind = 'dev-fast-repeat'
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  timings = [ordered]@{
    elapsedMilliseconds = 1500
    elapsedSeconds = 1.5
  }
  finalStatus = 'succeeded'
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement.json') -Encoding utf8
[ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = '2026-03-19T00:00:01Z'
  latest = [ordered]@{}
  selectedSamples = [ordered]@{}
  comparisons = [ordered]@{}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json') -Encoding utf8
if ($PassThru) {
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath $refinementScript -Encoding utf8

    $result = & $sessionScript `
      -Profile 'dev-fast' `
      -RepoRoot $repoUnderTest `
      -ResultsRoot $resultsRoot `
      -LocalRefinementScriptPath $refinementScript `
      -PassThru

    $result.schema | Should -Be 'comparevi/local-operator-session@v1'
    $result.runtimeProfile | Should -Be 'dev-fast'
    $result.review.status | Should -Be 'not-requested'
    $result.localRefinement.schema | Should -Be 'comparevi/local-refinement@v1'
    $result.artifacts.sessionPath | Should -Be (Join-Path $resultsRoot 'local-operator-session.json')
    $result.artifacts.localRefinementPath | Should -Be (Join-Path $resultsRoot 'local-refinement.json')
    $result.artifacts.benchmarkPath | Should -Be (Join-Path $resultsRoot 'local-refinement-benchmark.json')
    $result.finalStatus | Should -Be 'succeeded'

    & $schemaScript -JsonPath $result.artifacts.sessionPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0
  }

  It 'normalizes noisy local refinement pass-thru output before writing the session manifest' {
    $repoUnderTest = Join-Path $TestDrive 'repo-noisy-refinement'
    $resultsRoot = Join-Path $repoUnderTest 'tests/results/local-vi-history/dev-fast'
    $refinementScript = Join-Path $TestDrive 'Invoke-VIHistoryLocalRefinement.noisy.stub.ps1'
    New-Item -ItemType Directory -Path (Join-Path $repoUnderTest 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    @'
param(
  [string]$Profile = 'dev-fast',
  [string]$RepoRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { (Get-Location).Path } else { $RepoRoot }
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/dev-fast'
} else {
  $ResultsRoot
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  image = 'comparevi-vi-history-dev:local'
  toolSource = 'local-dev-image'
  cacheReuseState = 'existing-local-image'
  coldWarmClass = 'warm'
  benchmarkSampleKind = 'dev-fast-repeat'
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  timings = [ordered]@{
    elapsedMilliseconds = 1500
    elapsedSeconds = 1.5
  }
  finalStatus = 'succeeded'
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement.json') -Encoding utf8
[ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = '2026-03-19T00:00:01Z'
  latest = [ordered]@{}
  selectedSamples = [ordered]@{}
  comparisons = [ordered]@{}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json') -Encoding utf8
if ($PassThru) {
  'runtime-noise'
  [ordered]@{ kind = 'intermediate' }
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath $refinementScript -Encoding utf8

    $result = & $sessionScript `
      -Profile 'dev-fast' `
      -RepoRoot $repoUnderTest `
      -ResultsRoot $resultsRoot `
      -LocalRefinementScriptPath $refinementScript `
      -PassThru

    $result.schema | Should -Be 'comparevi/local-operator-session@v1'
    $result.runtimeProfile | Should -Be 'dev-fast'
    $result.localRefinement.schema | Should -Be 'comparevi/local-refinement@v1'
    $result.localRefinement.finalStatus | Should -Be 'succeeded'
    Test-Path -LiteralPath (Join-Path $resultsRoot 'local-operator-session.json') | Should -BeTrue

    & $schemaScript -JsonPath $result.artifacts.sessionPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0
  }

  It 'records downstream review outputs when a review hook is provided' {
    $repoUnderTest = Join-Path $TestDrive 'repo-with-review'
    $resultsRoot = Join-Path $repoUnderTest 'tests/results/local-vi-history/warm-dev'
    $refinementScript = Join-Path $TestDrive 'Invoke-VIHistoryLocalRefinement.with-review.stub.ps1'
    $reviewScript = Join-Path $TestDrive 'Invoke-ReviewHook.stub.ps1'
    New-Item -ItemType Directory -Path (Join-Path $repoUnderTest 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    @'
param(
  [string]$Profile = 'warm-dev',
  [string]$RepoRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { (Get-Location).Path } else { $RepoRoot }
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/warm-dev'
} else {
  $ResultsRoot
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
$runtimeArtifacts = Join-Path $resolvedResultsRoot 'runtime'
New-Item -ItemType Directory -Path $runtimeArtifacts -Force | Out-Null
$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  image = 'comparevi-vi-history-dev:local'
  toolSource = 'local-dev-image'
  cacheReuseState = 'warm-runtime-reused'
  coldWarmClass = 'warm'
  benchmarkSampleKind = 'warm-dev-repeat'
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  timings = [ordered]@{
    elapsedMilliseconds = 1200
    elapsedSeconds = 1.2
  }
  warmRuntime = [ordered]@{
    schema = 'comparevi/local-runtime-state@v1'
    action = 'reconcile'
    outcome = 'healthy'
    artifacts = [ordered]@{
      statePath = (Join-Path $runtimeArtifacts 'local-runtime-state.json')
      healthPath = (Join-Path $runtimeArtifacts 'local-runtime-health.json')
      leasePath = (Join-Path $runtimeArtifacts 'local-runtime-lease.json')
    }
  }
  finalStatus = 'succeeded'
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement.json') -Encoding utf8
[ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = '2026-03-19T00:00:01Z'
  latest = [ordered]@{}
  selectedSamples = [ordered]@{}
  comparisons = [ordered]@{}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json') -Encoding utf8
if ($PassThru) {
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath $refinementScript -Encoding utf8

    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bundlePath = $env:COMPAREVI_REVIEW_BUNDLE_PATH
$workspaceHtmlPath = $env:COMPAREVI_REVIEW_WORKSPACE_HTML_PATH
$workspaceMarkdownPath = $env:COMPAREVI_REVIEW_WORKSPACE_MARKDOWN_PATH
$previewManifestPath = $env:COMPAREVI_REVIEW_PREVIEW_MANIFEST_PATH
$runPath = $env:COMPAREVI_REVIEW_RUN_PATH
$reviewReceiptPath = $env:COMPAREVI_REVIEW_RECEIPT_PATH
foreach ($path in @($bundlePath, $workspaceHtmlPath, $workspaceMarkdownPath, $previewManifestPath, $runPath, $reviewReceiptPath)) {
  if (-not [string]::IsNullOrWhiteSpace($path)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -LiteralPath $path -Value 'stub' -Encoding utf8
  }
}
exit 0
'@ | Set-Content -LiteralPath $reviewScript -Encoding utf8

    $reviewBundlePath = Join-Path $resultsRoot 'review-bundle.json'
    $workspaceHtmlPath = Join-Path $resultsRoot 'index.html'
    $workspaceMarkdownPath = Join-Path $resultsRoot 'index.md'
    $previewManifestPath = Join-Path $resultsRoot 'pr-preview-manifest.json'
    $runPath = Join-Path $resultsRoot 'pr-run.json'
    $reviewReceiptPath = Join-Path $resultsRoot 'local-review.json'

    $result = & $sessionScript `
      -Profile 'warm-dev' `
      -RepoRoot $repoUnderTest `
      -ResultsRoot $resultsRoot `
      -LocalRefinementScriptPath $refinementScript `
      -ReviewCommandPath $reviewScript `
      -ReviewWorkingDirectory $repoUnderTest `
      -ReviewBundlePath $reviewBundlePath `
      -ReviewWorkspaceHtmlPath $workspaceHtmlPath `
      -ReviewWorkspaceMarkdownPath $workspaceMarkdownPath `
      -ReviewPreviewManifestPath $previewManifestPath `
      -ReviewRunPath $runPath `
      -ReviewReceiptPath $reviewReceiptPath `
      -PassThru

    $result.review.status | Should -Be 'succeeded'
    $result.review.commandPath | Should -Be $reviewScript
    $result.review.outputs.reviewBundlePath | Should -Be $reviewBundlePath
    $result.review.outputs.workspaceHtmlPath | Should -Be $workspaceHtmlPath
    $result.artifacts.reviewReceiptPath | Should -Be $reviewReceiptPath
    $result.artifacts.warmRuntimeStatePath | Should -Be (Join-Path $resultsRoot 'runtime/local-runtime-state.json')
    Test-Path -LiteralPath $reviewBundlePath | Should -BeTrue
    Test-Path -LiteralPath $workspaceHtmlPath | Should -BeTrue
    Test-Path -LiteralPath $workspaceMarkdownPath | Should -BeTrue
    Test-Path -LiteralPath $previewManifestPath | Should -BeTrue
    Test-Path -LiteralPath $runPath | Should -BeTrue
    Test-Path -LiteralPath $reviewReceiptPath | Should -BeTrue

    & $schemaScript -JsonPath $result.artifacts.sessionPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0
  }

  It 'resolves the local refinement script from ToolingRoot while keeping RepoRoot as the consumer workspace' {
    $consumerRepoRoot = Join-Path $TestDrive 'consumer-repo'
    $toolingRoot = Join-Path $TestDrive 'tooling-root'
    $resultsRoot = Join-Path $consumerRepoRoot 'tests/results/local-vi-history/dev-fast'
    $capturePath = Join-Path $TestDrive 'operator-session-cross-repo-capture.json'
    New-Item -ItemType Directory -Path (Join-Path $consumerRepoRoot 'Tooling/deployment') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $consumerRepoRoot 'Tooling/deployment/Test.vi') -Value 'consumer-target' -Encoding utf8
    New-Item -ItemType Directory -Path (Join-Path $toolingRoot 'tools') -Force | Out-Null

    @'
param(
  [string]$Profile = 'dev-fast',
  [string]$RepoRoot = '',
  [string]$ToolingRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$capturePath = $env:COMPAREVI_TOOLING_CAPTURE_PATH
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { (Get-Location).Path } else { [System.IO.Path]::GetFullPath($RepoRoot) }
$resolvedToolingRoot = if ([string]::IsNullOrWhiteSpace($ToolingRoot)) { '' } else { [System.IO.Path]::GetFullPath($ToolingRoot) }
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/dev-fast'
} else {
  [System.IO.Path]::GetFullPath($ResultsRoot)
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
[ordered]@{
  repoRoot = $resolvedRepoRoot
  toolingRoot = $resolvedToolingRoot
  resultsRoot = $resolvedResultsRoot
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $capturePath -Encoding utf8
$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  image = 'comparevi-vi-history-dev:local'
  toolSource = 'local-dev-image'
  cacheReuseState = 'existing-local-image'
  coldWarmClass = 'warm'
  benchmarkSampleKind = 'dev-fast-repeat'
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  timings = [ordered]@{
    elapsedMilliseconds = 900
    elapsedSeconds = 0.9
  }
  finalStatus = 'succeeded'
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement.json') -Encoding utf8
[ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = '2026-03-19T00:00:01Z'
  latest = [ordered]@{}
  selectedSamples = [ordered]@{}
  comparisons = [ordered]@{}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json') -Encoding utf8
if ($PassThru) {
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath (Join-Path $toolingRoot 'tools' 'Invoke-VIHistoryLocalRefinement.ps1') -Encoding utf8

    $originalCapturePath = $env:COMPAREVI_TOOLING_CAPTURE_PATH
    try {
      $env:COMPAREVI_TOOLING_CAPTURE_PATH = $capturePath
      $result = & $sessionScript `
        -Profile 'dev-fast' `
        -RepoRoot $consumerRepoRoot `
        -ToolingRoot $toolingRoot `
        -HistoryTargetPath 'Tooling/deployment/Test.vi' `
        -ResultsRoot $resultsRoot `
        -PassThru
    } finally {
      if ($null -eq $originalCapturePath) {
        Remove-Item Env:COMPAREVI_TOOLING_CAPTURE_PATH -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_TOOLING_CAPTURE_PATH = $originalCapturePath
      }
    }

    $result.finalStatus | Should -Be 'succeeded'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 10
    $capture.repoRoot | Should -Be $consumerRepoRoot
    $capture.toolingRoot | Should -Be $toolingRoot
    $capture.resultsRoot | Should -Be $resultsRoot
    $result.artifacts.sessionPath | Should -Be (Join-Path $resultsRoot 'local-operator-session.json')

    & $schemaScript -JsonPath $result.artifacts.sessionPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0
  }

  It 'projects windows mirror proof artifacts through the session manifest' {
    $repoUnderTest = Join-Path $TestDrive 'repo-windows-mirror'
    $resultsRoot = Join-Path $repoUnderTest 'tests/results/local-vi-history/windows-mirror-proof'
    $refinementScript = Join-Path $TestDrive 'Invoke-VIHistoryLocalRefinement.windows-mirror.stub.ps1'
    New-Item -ItemType Directory -Path (Join-Path $repoUnderTest 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoUnderTest 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    @'
param(
  [string]$Profile = 'windows-mirror-proof',
  [string]$RepoRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { (Get-Location).Path } else { $RepoRoot }
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/windows-mirror-proof'
} else {
  $ResultsRoot
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  runtimePlane = 'windows-mirror'
  image = 'nationalinstruments/labview:2026q1-windows'
  toolSource = 'windows-mirror-proof-image'
  cacheReuseState = 'canonical-windows-proof-image'
  coldWarmClass = 'cold'
  benchmarkSampleKind = 'windows-mirror-proof-cold'
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  timings = [ordered]@{
    elapsedMilliseconds = 2100
    elapsedSeconds = 2.1
  }
  windowsMirror = [ordered]@{
    hostPreflight = [ordered]@{
      path = (Join-Path $resolvedResultsRoot 'windows-ni-2026q1-host-preflight.json')
    }
    compare = [ordered]@{
      reportPath = (Join-Path $resolvedResultsRoot 'windows-mirror-report.html')
      capturePath = (Join-Path $resolvedResultsRoot 'ni-windows-container-capture.json')
      runtimeSnapshotPath = (Join-Path $resolvedResultsRoot 'windows-mirror-runtime-snapshot.json')
      status = 'diff'
      classification = 'diff'
      resultClass = 'diff'
      gateOutcome = 'pass'
      failureClass = 'none'
    }
    headlessContract = [ordered]@{
      required = $true
      labviewCliMode = 'headless'
    }
    labviewPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
  }
  finalStatus = 'succeeded'
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement.json') -Encoding utf8
[ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = '2026-03-19T00:00:01Z'
  latest = [ordered]@{}
  selectedSamples = [ordered]@{}
  comparisons = [ordered]@{}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json') -Encoding utf8
foreach ($path in @(
    (Join-Path $resolvedResultsRoot 'windows-ni-2026q1-host-preflight.json'),
    (Join-Path $resolvedResultsRoot 'windows-mirror-report.html'),
    (Join-Path $resolvedResultsRoot 'ni-windows-container-capture.json'),
    (Join-Path $resolvedResultsRoot 'windows-mirror-runtime-snapshot.json')
  )) {
  Set-Content -LiteralPath $path -Value 'stub' -Encoding utf8
}
if ($PassThru) {
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath $refinementScript -Encoding utf8

    $result = & $sessionScript `
      -Profile 'windows-mirror-proof' `
      -RepoRoot $repoUnderTest `
      -ResultsRoot $resultsRoot `
      -LocalRefinementScriptPath $refinementScript `
      -PassThru

    $result.runtimeProfile | Should -Be 'windows-mirror-proof'
    $result.runtimePlane | Should -Be 'windows-mirror'
    $result.localRefinement.runtimePlane | Should -Be 'windows-mirror'
    $result.localRefinement.windowsMirror.compare.reportPath | Should -Be (Join-Path $resultsRoot 'windows-mirror-report.html')
    $result.artifacts.windowsMirrorHostPreflightPath | Should -Be (Join-Path $resultsRoot 'windows-ni-2026q1-host-preflight.json')
    $result.artifacts.windowsMirrorCapturePath | Should -Be (Join-Path $resultsRoot 'ni-windows-container-capture.json')
    $result.artifacts.windowsMirrorRuntimeSnapshotPath | Should -Be (Join-Path $resultsRoot 'windows-mirror-runtime-snapshot.json')
    $result.finalStatus | Should -Be 'succeeded'

    & $schemaScript -JsonPath $result.artifacts.sessionPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0
  }
}
