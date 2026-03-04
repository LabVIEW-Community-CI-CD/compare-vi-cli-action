#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$Configuration = 'Release',
  [string]$ResultsRoot = 'tests/results/_agent/cli-maturity',
  [string]$EmitJsonSummary,
  [switch]$AppendStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRootPath {
  param([string]$Provided)

  if (-not [string]::IsNullOrWhiteSpace($Provided)) {
    return (Resolve-Path -LiteralPath $Provided).Path
  }

  $current = (Get-Location).Path
  while ($true) {
    if (Test-Path -LiteralPath (Join-Path $current '.git')) {
      return $current
    }

    $parent = Split-Path -Parent $current
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
      throw 'Could not locate repository root (.git). Pass -RepoRoot explicitly.'
    }

    $current = $parent
  }
}

function Invoke-CliCommand {
  param(
    [string]$RepoPath,
    [string[]]$Arguments,
    [int]$ExpectedExitCode,
    [string]$Name,
    [string]$ExpectedGate,
    [string]$ExpectedFailureClass,
    [switch]$RequireArtifacts,
    [string[]]$ExpectedFiles = @()
  )

  $outputText = (& dotnet run --project (Join-Path $RepoPath 'src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj') -c $Configuration -- @Arguments) 2>&1
  $exitCode = $LASTEXITCODE
  $joined = @($outputText) -join [Environment]::NewLine

  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Name expected exitCode=$ExpectedExitCode but got $exitCode. Output: $joined"
  }

  $payload = $null
  try {
    $payload = $joined | ConvertFrom-Json -Depth 50
  }
  catch {
    throw "$Name did not emit valid JSON payload. Output: $joined"
  }

  $gate = [string]$payload.gateOutcome
  $failureClass = [string]$payload.failureClass
  $resultClass = if ($payload.PSObject.Properties['resultClass']) { [string]$payload.resultClass } else { '' }
  $dryRun = if ($payload.PSObject.Properties['dryRun']) { [bool]$payload.dryRun } else { $false }
  if ($gate -ne $ExpectedGate) {
    throw "$Name expected gateOutcome='$ExpectedGate' but got '$gate'"
  }
  if ($failureClass -ne $ExpectedFailureClass) {
    throw "$Name expected failureClass='$ExpectedFailureClass' but got '$failureClass'"
  }

  foreach ($path in $ExpectedFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "$Name missing expected artifact: $path"
    }
  }

  if ($RequireArtifacts.IsPresent) {
    if (-not $payload.PSObject.Properties['artifacts']) {
      throw "$Name did not include artifacts payload"
    }

    $artifactObject = $payload.artifacts
    foreach ($artifactKey in @('summaryJsonPath','summaryMarkdownPath','reportHtmlPath','imageIndexPath','runLogPath')) {
      if (-not $artifactObject.PSObject.Properties[$artifactKey]) {
        throw "$Name artifacts payload missing key: $artifactKey"
      }

      $artifactPath = [string]$artifactObject.$artifactKey
      if ([string]::IsNullOrWhiteSpace($artifactPath)) {
        throw "$Name artifacts payload had empty path for key: $artifactKey"
      }

      if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "$Name missing expected artifact file from payload: $artifactPath"
      }
    }
  }

  return [pscustomobject]@{
    name = $Name
    exitCode = $exitCode
    gateOutcome = $gate
    failureClass = $failureClass
    resultClass = $resultClass
    dryRun = $dryRun
  }
}

$repoPath = Resolve-RepoRootPath -Provided $RepoRoot
Push-Location $repoPath
try {
  $resultsRootResolved = if ([IO.Path]::IsPathRooted($ResultsRoot)) { $ResultsRoot } else { Join-Path $repoPath $ResultsRoot }
  if (Test-Path -LiteralPath $resultsRootResolved -PathType Container) {
    Remove-Item -LiteralPath $resultsRootResolved -Recurse -Force
  }
  New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null

  $projectPath = Join-Path $repoPath 'src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj'
  & dotnet build $projectPath -c $Configuration | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'dotnet build failed for CompareVi.Tools.Cli'
  }

  $laneInput = [ordered]@{
    fixture = 'maturity-smoke'
    baseVi = 'fixtures/vi-stage/bd-cosmetic/Base.vi'
    headVi = 'fixtures/vi-stage/bd-cosmetic/Head.vi'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    note = 'CLI maturity milestone assertion input'
  }
  $inputPath = Join-Path $resultsRootResolved 'lane-input.json'
  $laneInput | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputPath -Encoding utf8

  $reportInputPath = Join-Path $resultsRootResolved 'report-input.json'
  @{ summary = 'maturity' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportInputPath -Encoding utf8

  $checks = New-Object System.Collections.Generic.List[object]

  $singleRealOut = Join-Path $resultsRootResolved 'compare-single-real'
  New-Item -ItemType Directory -Path $singleRealOut -Force | Out-Null
  $checks.Add((Invoke-CliCommand -RepoPath $repoPath -Name 'compare-single-real' -ExpectedExitCode 0 -ExpectedGate 'pass' -ExpectedFailureClass 'none' -ExpectedFiles @(
      (Join-Path $singleRealOut 'compare-single-summary.json')) -RequireArtifacts -Arguments @('compare','single','--input',$inputPath,'--out-dir',$singleRealOut,'--headless')))

  $singleDryOut = Join-Path $resultsRootResolved 'compare-single-dry'
  New-Item -ItemType Directory -Path $singleDryOut -Force | Out-Null
  $checks.Add((Invoke-CliCommand -RepoPath $repoPath -Name 'compare-single-dry' -ExpectedExitCode 0 -ExpectedGate 'pass' -ExpectedFailureClass 'none' -Arguments @('compare','single','--input',$inputPath,'--out-dir',$singleDryOut,'--dry-run','--headless')))

  $singlePolicyOut = Join-Path $resultsRootResolved 'compare-single-policy'
  New-Item -ItemType Directory -Path $singlePolicyOut -Force | Out-Null
  $checks.Add((Invoke-CliCommand -RepoPath $repoPath -Name 'compare-single-policy' -ExpectedExitCode 1 -ExpectedGate 'fail' -ExpectedFailureClass 'preflight' -Arguments @('compare','single','--input',$inputPath,'--out-dir',$singlePolicyOut,'--non-interactive')))

  $rangeRealOut = Join-Path $resultsRootResolved 'compare-range-real'
  New-Item -ItemType Directory -Path $rangeRealOut -Force | Out-Null
  $checks.Add((Invoke-CliCommand -RepoPath $repoPath -Name 'compare-range-real' -ExpectedExitCode 0 -ExpectedGate 'pass' -ExpectedFailureClass 'none' -RequireArtifacts -Arguments @('compare','range','--base','HEAD~1','--head','HEAD','--out-dir',$rangeRealOut,'--headless')))

  $historyRealOut = Join-Path $resultsRootResolved 'history-run-real'
  New-Item -ItemType Directory -Path $historyRealOut -Force | Out-Null
  $checks.Add((Invoke-CliCommand -RepoPath $repoPath -Name 'history-run-real' -ExpectedExitCode 0 -ExpectedGate 'pass' -ExpectedFailureClass 'none' -RequireArtifacts -Arguments @('history','run','--input',$inputPath,'--out-dir',$historyRealOut,'--headless')))

  $reportRealOut = Join-Path $resultsRootResolved 'report-consolidate-real'
  New-Item -ItemType Directory -Path $reportRealOut -Force | Out-Null
  $checks.Add((Invoke-CliCommand -RepoPath $repoPath -Name 'report-consolidate-real' -ExpectedExitCode 0 -ExpectedGate 'pass' -ExpectedFailureClass 'none' -RequireArtifacts -Arguments @('report','consolidate','--input',$reportInputPath,'--out-dir',$reportRealOut,'--headless')))

  $checkArray = @($checks.ToArray())

  $summary = [ordered]@{
    schema = 'comparevi-cli/maturity-check@v1'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    configuration = $Configuration
    resultsRoot = $resultsRootResolved
    checks = $checkArray
    status = 'pass'
  }

  if ([string]::IsNullOrWhiteSpace($EmitJsonSummary)) {
    $summaryPath = Join-Path $resultsRootResolved 'maturity-summary.json'
  }
  else {
    $summaryPath = if ([IO.Path]::IsPathRooted($EmitJsonSummary)) { $EmitJsonSummary } else { Join-Path $repoPath $EmitJsonSummary }
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $summaryPath) -Force | Out-Null
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8

  if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
    $lines = @(
      '### CLI maturity milestone gate',
      ('- Status: `pass`'),
      ('- Configuration: `{0}`' -f $Configuration),
      ('- Results root: `{0}`' -f $resultsRootResolved),
      ('- Summary: `{0}`' -f $summaryPath),
      '- Checks:'
    )
    foreach ($check in $checkArray) {
      $lines += ('  - `{0}` => exit `{1}`, gate `{2}`, failure `{3}`' -f $check.name, $check.exitCode, $check.gateOutcome, $check.failureClass)
    }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($lines -join [Environment]::NewLine)
  }

  $summary | ConvertTo-Json -Depth 8
}
finally {
  Pop-Location
}
