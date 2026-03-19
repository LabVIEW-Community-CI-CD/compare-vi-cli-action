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
}
