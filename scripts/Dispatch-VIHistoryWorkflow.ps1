param(
  [Parameter(Mandatory = $true)]
  [string]$ViPath,
  [string]$CompareRef = '',
  [int]$CompareDepth = 10,
  [switch]$FailFast,
  [switch]$FailOnDiff,
  [string]$Modes = 'default',
  [string]$IgnoreFlags = 'none',
  [string]$NotifyIssue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$handoffDir = Join-Path $repoRoot 'tests' 'results' '_agent' 'handoff'
$runRecordPath = Join-Path $handoffDir 'vi-history-run.json'

$arguments = @(
  'workflow', 'run', 'vi-compare-refs.yml',
  '-f', "vi_path=$ViPath",
  '-f', "compare_depth=$CompareDepth",
  '-f', "compare_modes=$Modes",
  '-f', "compare_ignore_flags=$IgnoreFlags"
)

if (-not [string]::IsNullOrWhiteSpace($CompareRef)) {
  $arguments += @('-f', "compare_ref=$CompareRef")
}
if ($FailFast.IsPresent) {
  $arguments += @('-f', 'compare_fail_fast=true')
}
if ($FailOnDiff.IsPresent) {
  $arguments += @('-f', 'compare_fail_on_diff=true')
}
if (-not [string]::IsNullOrWhiteSpace($NotifyIssue)) {
  $arguments += @('-f', "notify_issue=$NotifyIssue")
}

Write-Host "gh $($arguments -join ' ')"
$runDispatch = gh @arguments
Write-Host $runDispatch

if ($LASTEXITCODE -ne 0) { return }

try {
  $currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
} catch {
  $currentBranch = ''
}

$branchFilter = if (-not [string]::IsNullOrWhiteSpace($CompareRef)) {
  $CompareRef
} elseif (-not [string]::IsNullOrWhiteSpace($currentBranch)) {
  $currentBranch
} else {
  ''
}

$runListArgs = @('run','list','--workflow','vi-compare-refs.yml','--limit','1','--json','databaseId,url,headBranch,status,createdAt,displayTitle')
if (-not [string]::IsNullOrWhiteSpace($branchFilter)) {
  $runListArgs += @('--branch', $branchFilter)
}

function Write-TrackingHint {
  Write-Host 'Workflow dispatched; use "gh run list --workflow vi-compare-refs.yml" to track progress.' -ForegroundColor Yellow
}

try {
  $run = $null
  for ($attempt = 0; $attempt -lt 3 -and -not $run; $attempt++) {
    if ($attempt -gt 0) {
      Start-Sleep -Seconds 2
    }

    $runJson = $null
    try {
      $runJson = gh @runListArgs 2>$null
    } catch {
      $runJson = $null
    }

    if (-not $runJson) { continue }

    try {
      $runInfo = $runJson | ConvertFrom-Json
    } catch {
      continue
    }

    if ($runInfo) {
      if ($runInfo -is [System.Array]) {
        if ($runInfo.Count -gt 0) {
          $run = $runInfo[0]
        }
      } else {
        $run = $runInfo
      }
    }
  }

  if ($run) {
    $runId = if ($run.PSObject.Properties['databaseId']) { $run.databaseId } else { $null }
    $runUrl = if ($run.PSObject.Properties['url']) { $run.url } else { $null }
    $runBranch = if ($run.PSObject.Properties['headBranch']) { $run.headBranch } else { '(unknown)' }
    if ($runId -and $runUrl) {
      Write-Host ("Latest run for branch '{0}': #{1} -> {2}" -f $runBranch, $runId, $runUrl) -ForegroundColor Cyan
    } elseif ($runUrl) {
      Write-Host ("Latest run for branch '{0}': {1}" -f $runBranch, $runUrl) -ForegroundColor Cyan
    } else {
      Write-Host ("Latest run for branch '{0}' queued (run id unavailable)." -f $runBranch) -ForegroundColor Cyan
    }

    try {
      if (-not (Test-Path -LiteralPath $handoffDir -PathType Container)) {
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
      }

      $record = [ordered]@{
        schema      = 'vi-history/dispatch@v1'
        generatedAt = (Get-Date).ToString('o')
        workflow    = 'vi-compare-refs.yml'
        inputs      = @{
          viPath             = $ViPath
          compareRef         = $CompareRef
          compareDepth       = $CompareDepth
          compareModes       = $Modes
          compareIgnoreFlags = $IgnoreFlags
          notifyIssue        = $NotifyIssue
          failFast           = [bool]$FailFast.IsPresent
          failOnDiff         = [bool]$FailOnDiff.IsPresent
        }
        run         = @{
          id           = $runId
          url          = $runUrl
          headBranch   = $runBranch
          status       = if ($run.PSObject.Properties['status']) { $run.status } else { $null }
          createdAt    = if ($run.PSObject.Properties['createdAt']) { $run.createdAt } else { $null }
          displayTitle = if ($run.PSObject.Properties['displayTitle']) { $run.displayTitle } else { $null }
        }
      }

      $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runRecordPath -Encoding UTF8
    } catch {
      Write-Warning ("Failed to write run metadata to {0}: {1}" -f $runRecordPath, $_.Exception.Message)
    }
  } else {
    Write-TrackingHint
  }
} catch {
  Write-TrackingHint
}
