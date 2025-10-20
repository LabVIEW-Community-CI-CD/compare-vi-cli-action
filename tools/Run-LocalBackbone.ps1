param(
  [switch]$SkipPrioritySync,
  [string[]]$CompareViName,
  [string]$CompareBranch = 'HEAD',
  [int]$CompareMaxPairs = 1,
  [switch]$CompareIncludeIdenticalPairs,
  [switch]$CompareFailOnDiff,
  [string]$CompareLvCompareArgs,
  [string]$CompareResultsDir,
  [switch]$SkipCompareHistory,
  [string]$AdditionalScriptPath,
  [string[]]$AdditionalScriptArguments,
  [switch]$IncludeIntegration,
  [switch]$SkipPester,
  [switch]$UseLocalRunTests,
  [switch]$SkipPrePushChecks,
  [string]$PushTarget = 'standing',
  [switch]$RunWatcherUpdate,
  [string]$WatcherJson,
  [string]$WatcherResultsDir = 'tests/results',
  [switch]$CheckLvEnv,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path

function Invoke-BackboneStep {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action,
    [switch]$SkipWhenDryRun
  )

  Write-Host ""
  Write-Host ("=== {0} ===" -f $Name) -ForegroundColor Cyan
  if ($DryRun -and $SkipWhenDryRun) {
    Write-Host "[dry-run] Step skipped by request." -ForegroundColor Yellow
    return
  }

  if ($DryRun) {
    Write-Host "[dry-run] Step would execute; skipping actual invocation." -ForegroundColor Yellow
    return
  }

  & $Action
  $exit = $LASTEXITCODE
  if ($exit -ne 0) {
    throw ("Step '{0}' failed with exit code {1}." -f $Name, $exit)
  }
}

Push-Location $repoRoot
try {
  Write-Host "Repository root: $repoRoot" -ForegroundColor Gray

  if (-not $SkipPrioritySync) {
    Invoke-BackboneStep -Name 'priority:sync' -Action {
      & node tools/npm/run-script.mjs priority:sync
    }
  } else {
    Write-Host "Skipping priority sync as requested." -ForegroundColor Yellow
  }

  if (-not $SkipCompareHistory -and $CompareViName -and $CompareViName.Count -gt 0) {
    $viNames = $CompareViName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($vi in $viNames) {
      $label = "compare-history ($vi)"
      Invoke-BackboneStep -Name $label -Action {
        $args = @(
          '-NoLogo', '-NoProfile',
          '-File', (Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1'),
          '-ViName', $vi,
          '-Branch', $CompareBranch,
          '-MaxPairs', [Math]::Max(1, $CompareMaxPairs)
        )
        if ($CompareIncludeIdenticalPairs) { $args += '-IncludeIdenticalPairs' }
        if ($CompareFailOnDiff) { $args += '-FailOnDiff' }
        if ($CompareLvCompareArgs) {
          $args += '-LvCompareArgs'
          $args += $CompareLvCompareArgs
        }
        if ($CompareResultsDir) {
          $args += '-ResultsDir'
          $args += $CompareResultsDir
        }
        & pwsh @args
      }
    }
  } elseif (-not $SkipCompareHistory) {
    Write-Host "Compare history step requested but no VI names supplied; skipping." -ForegroundColor Yellow
  } else {
    Write-Host "Skipping compare-history step as requested." -ForegroundColor Yellow
  }

  if ($AdditionalScriptPath) {
    $resolvedScript = Resolve-Path -LiteralPath (Join-Path $repoRoot $AdditionalScriptPath) -ErrorAction Stop
    Invoke-BackboneStep -Name ("custom-script ({0})" -f (Split-Path $resolvedScript -Leaf)) -Action {
      $args = @('-NoLogo', '-NoProfile', '-File', $resolvedScript)
      if ($AdditionalScriptArguments) {
        $args += $AdditionalScriptArguments
      }
      & pwsh @args
    }
  }

  if (-not $SkipPester) {
    if ($UseLocalRunTests) {
      Invoke-BackboneStep -Name 'Local-RunTests.ps1' -Action {
        $args = @('-NoLogo', '-NoProfile', '-File', (Join-Path $repoRoot 'tools' 'Local-RunTests.ps1'))
        if ($IncludeIntegration) { $args += '-IncludeIntegration' }
        & pwsh @args
      }
    } else {
      Invoke-BackboneStep -Name 'Invoke-PesterTests.ps1' -Action {
        $args = @('-NoLogo', '-NoProfile', '-File', (Join-Path $repoRoot 'Invoke-PesterTests.ps1'))
        $args += '-IntegrationMode'
        $args += (if ($IncludeIntegration) { 'include' } else { 'exclude' })
        & pwsh @args
      }
    }
  } else {
    Write-Host "Skipping Pester run as requested." -ForegroundColor Yellow
  }

  if ($RunWatcherUpdate) {
    if (-not $WatcherJson) {
      throw "Watcher update requested but -WatcherJson was not provided."
    }
    Invoke-BackboneStep -Name 'Update watcher telemetry' -Action {
      $args = @(
        '-NoLogo', '-NoProfile',
        '-File', (Join-Path $repoRoot 'tools' 'Update-SessionIndexWatcher.ps1'),
        '-ResultsDir', $WatcherResultsDir,
        '-WatcherJson', $WatcherJson
      )
      & pwsh @args
    }
  }

  if ($CheckLvEnv) {
    Invoke-BackboneStep -Name 'Test integration environment' -Action {
      $scriptPath = Join-Path $repoRoot 'scripts' 'Test-IntegrationEnvironment.ps1'
      & pwsh '-NoLogo' '-NoProfile' '-File' $scriptPath
    }
  }

  if (-not $SkipPrePushChecks) {
    Invoke-BackboneStep -Name 'Ensure push target (contract)' -Action {
      $args = @(
        '-NoLogo', '-NoProfile',
        '-File', (Join-Path $repoRoot 'tools' 'Ensure-AgentPushTarget.ps1'),
        '-RepositoryRoot', $repoRoot,
        '-SkipTrackingCheck'
      )
      if ($PushTarget) {
        $args += '-Target'
        $args += $PushTarget
      }
      & pwsh @args
    }
    Invoke-BackboneStep -Name 'PrePush-Checks.ps1' -Action {
      & pwsh '-NoLogo' '-NoProfile' '-File' (Join-Path $repoRoot 'tools' 'PrePush-Checks.ps1')
    }
  } else {
    Write-Host "Skipping PrePush-Checks as requested." -ForegroundColor Yellow
  }

  Write-Host ""
  Write-Host "Local backbone completed successfully." -ForegroundColor Green
}
catch {
  Write-Error $_
  exit 1
}
finally {
  Pop-Location
}
