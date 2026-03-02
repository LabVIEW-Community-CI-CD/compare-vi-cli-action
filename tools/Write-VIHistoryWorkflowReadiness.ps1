#Requires -Version 7.0
<#
.SYNOPSIS
  Writes workflow-lane readiness envelope for PR VI history runs.

.DESCRIPTION
  Creates additive machine-readable and markdown readiness artifacts from lane
  statuses (windows + linux smoke) and known summary artifact paths. Designed
  for use in reusable and direct PR VI history workflows.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$WindowsLaneStatus,
  [Parameter(Mandatory = $true)][string]$LinuxLaneStatus,
  [string]$WindowsDiffDetected = '',
  [string]$LinuxDiffDetected = '',
  [string]$WindowsFailureClass = '',
  [string]$LinuxFailureClass = '',
  [string]$ResultsRoot = 'tests/results/pr-vi-history',
  [string]$SummaryPath = '',
  [string]$LinuxSmokeSummaryPath = '',
  [string]$WindowsRuntimeSnapshotPath = '',
  [string]$LinuxRuntimeSnapshotPath = '',
  [string]$OutputJsonPath = '',
  [string]$OutputMarkdownPath = '',
  [string]$RunUrl = '',
  [string]$PrNumber = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory)][string]$Path)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Normalize-Status {
  param([AllowNull()][AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
  $normalized = $Value.Trim().ToLowerInvariant()
  switch -Regex ($normalized) {
    '^(success|ok|passed)$' { return 'success' }
    '^(failure|failed|error)$' { return 'failure' }
    '^(skipped|skip)$' { return 'skipped' }
    default { return $normalized }
  }
}

function Convert-ToBool {
  param(
    [AllowNull()][AllowEmptyString()][string]$Value,
    [bool]$Default = $false
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
  switch -Regex ($Value.Trim().ToLowerInvariant()) {
    '^(true|1|yes|y|on)$' { return $true }
    '^(false|0|no|n|off)$' { return $false }
    default { return $Default }
  }
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$DestPath
  )
  if ([string]::IsNullOrWhiteSpace($DestPath)) { return }
  Ensure-ParentDirectory -Path $DestPath
  if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
    New-Item -ItemType File -Path $DestPath -Force | Out-Null
  }
  Add-Content -LiteralPath $DestPath -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

$resultsRootResolved = Resolve-AbsolutePath -Path $ResultsRoot
if (-not (Test-Path -LiteralPath $resultsRootResolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null
}

$windows = Normalize-Status -Value $WindowsLaneStatus
$linux = Normalize-Status -Value $LinuxLaneStatus
$windowsDiff = Convert-ToBool -Value $WindowsDiffDetected -Default $false
$linuxDiff = Convert-ToBool -Value $LinuxDiffDetected -Default $false
$windowsFailure = if ([string]::IsNullOrWhiteSpace($WindowsFailureClass)) {
  if ($windows -eq 'success') { 'none' } elseif ($windows -eq 'failure') { 'cli/tool' } else { 'none' }
} else {
  $WindowsFailureClass.Trim().ToLowerInvariant()
}
$linuxFailure = if ([string]::IsNullOrWhiteSpace($LinuxFailureClass)) {
  if ($linux -eq 'success') { 'none' } elseif ($linux -eq 'failure') { 'preflight' } else { 'none' }
} else {
  $LinuxFailureClass.Trim().ToLowerInvariant()
}

$verdict = if ($windows -eq 'success' -and $linux -eq 'success') { 'ready' } else { 'not-ready' }
$recommendation = if ($verdict -eq 'ready') { 'proceed' } else { 'hold' }

$jsonOutResolved = if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  Join-Path $resultsRootResolved 'vi-history-workflow-readiness.json'
} else {
  Resolve-AbsolutePath -Path $OutputJsonPath
}
$mdOutResolved = if ([string]::IsNullOrWhiteSpace($OutputMarkdownPath)) {
  Join-Path $resultsRootResolved 'vi-history-workflow-readiness.md'
} else {
  Resolve-AbsolutePath -Path $OutputMarkdownPath
}

$envelope = [ordered]@{
  schema = 'vi-history/workflow-readiness@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  verdict = $verdict
  recommendation = $recommendation
  pullRequestNumber = $PrNumber
  runUrl = $RunUrl
  lanes = [ordered]@{
    windows = [ordered]@{
      status = $windows
      diffDetected = [bool]$windowsDiff
      failureClass = $windowsFailure
      runtimeSnapshotPath = $WindowsRuntimeSnapshotPath
      summaryPath = $SummaryPath
    }
    linux = [ordered]@{
      status = $linux
      diffDetected = [bool]$linuxDiff
      failureClass = $linuxFailure
      runtimeSnapshotPath = $LinuxRuntimeSnapshotPath
      smokeSummaryPath = $LinuxSmokeSummaryPath
    }
  }
}

Ensure-ParentDirectory -Path $jsonOutResolved
$envelope | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonOutResolved -Encoding utf8

$md = New-Object System.Collections.Generic.List[string]
$md.Add('### VI History Workflow Readiness') | Out-Null
$md.Add('') | Out-Null
$md.Add('| Metric | Value |') | Out-Null
$md.Add('| --- | --- |') | Out-Null
$md.Add(('| Verdict | `{0}` |' -f $verdict)) | Out-Null
$md.Add(('| Recommendation | `{0}` |' -f $recommendation)) | Out-Null
$md.Add(('| PR Number | `{0}` |' -f ($PrNumber ?? ''))) | Out-Null
$runUrlCell = if ([string]::IsNullOrWhiteSpace($RunUrl)) { '`' } else { "[link]($RunUrl)" }
$md.Add(('| Run URL | {0} |' -f $runUrlCell)) | Out-Null
$md.Add('') | Out-Null
$md.Add('| Lane | Status | Diff Detected | Failure Class | Runtime Snapshot | Summary |') | Out-Null
$md.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
$md.Add(('| windows | `{0}` | `{1}` | `{2}` | `{3}` | `{4}` |' -f $windows, $windowsDiff, $windowsFailure, ($WindowsRuntimeSnapshotPath ?? ''), ($SummaryPath ?? ''))) | Out-Null
$md.Add(('| linux | `{0}` | `{1}` | `{2}` | `{3}` | `{4}` |' -f $linux, $linuxDiff, $linuxFailure, ($LinuxRuntimeSnapshotPath ?? ''), ($LinuxSmokeSummaryPath ?? ''))) | Out-Null
$md.Add('') | Out-Null
$md.Add(('- Readiness JSON: `{0}`' -f $jsonOutResolved)) | Out-Null

Ensure-ParentDirectory -Path $mdOutResolved
$md | Set-Content -LiteralPath $mdOutResolved -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  Ensure-ParentDirectory -Path $StepSummaryPath
  $md | Add-Content -LiteralPath $StepSummaryPath -Encoding utf8
}

Write-GitHubOutput -Key 'workflow-readiness-json-path' -Value $jsonOutResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'workflow-readiness-markdown-path' -Value $mdOutResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'workflow-readiness-verdict' -Value $verdict -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'workflow-readiness-recommendation' -Value $recommendation -DestPath $GitHubOutputPath

Write-Host ("[vi-history-workflow-readiness] verdict={0} recommendation={1}" -f $verdict, $recommendation)
Write-Host ("[vi-history-workflow-readiness] json={0}" -f $jsonOutResolved)
Write-Host ("[vi-history-workflow-readiness] markdown={0}" -f $mdOutResolved)
Write-Output $jsonOutResolved
