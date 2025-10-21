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

function Invoke-RogueSweep {
  param(
    [string]$RepoRoot,
    [int]$LookBackSeconds = 900,
    [int]$MaxAttempts = 3
  )

  if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path '.').Path
  }

  $attempts = [Math]::Max(1, [int][math]::Abs($MaxAttempts))
  $detectScript = Join-Path $RepoRoot 'tools' 'Detect-RogueLV.ps1'
  $closeScript = Join-Path $RepoRoot 'tools' 'Close-LabVIEW.ps1'
  $resultsDir = Join-Path $RepoRoot 'tests' 'results'

  if (-not (Test-Path -LiteralPath $detectScript -PathType Leaf)) {
    throw "Detect-RogueLV.ps1 not found; aborting rogue sweep."
  }

  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    $label = ("[rogue-sweep] Detect-RogueLV attempt {0}/{1}" -f $attempt, $attempts)
    Write-Host $label -ForegroundColor Yellow

    & pwsh '-NoLogo' '-NoProfile' '-File' $detectScript `
      '-ResultsDir' $resultsDir `
      '-LookBackSeconds' ([int][math]::Abs($LookBackSeconds)) `
      '-AppendToStepSummary' `
      '-FailOnRogue'

    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
      Write-Host '[rogue-sweep] No rogue LVCompare/LabVIEW processes detected.' -ForegroundColor DarkGreen
      return $true
    }

    if ($exitCode -ne 3) {
      throw ("Detect-RogueLV.ps1 exited with code {0}." -f $exitCode)
    }

    if ($attempt -eq $attempts) {
      break
    }

    Write-Warning '[rogue-sweep] Rogue processes detected; attempting cleanup before retry.'

    if (Test-Path -LiteralPath $closeScript -PathType Leaf) {
      try {
        & pwsh '-NoLogo' '-NoProfile' '-File' $closeScript | Out-Null
        Write-Host '[rogue-sweep] Close-LabVIEW.ps1 invoked.' -ForegroundColor DarkGray
      } catch {
        Write-Warning ("[rogue-sweep] Close-LabVIEW.ps1 failed: {0}" -f $_.Exception.Message)
      }
    }

    $liveProcs = @()
    try {
      $liveProcs = @(Get-Process -Name 'LabVIEW','LVCompare' -ErrorAction SilentlyContinue)
    } catch {
      Write-Warning ("[rogue-sweep] Failed to query LabVIEW/LVCompare processes: {0}" -f $_.Exception.Message)
      $liveProcs = @()
    }

    if ($liveProcs.Count -gt 0) {
      try {
        $ids = $liveProcs.Id
        Stop-Process -Id $ids -Force -ErrorAction Stop
        Write-Warning ("[rogue-sweep] Forced termination issued for PID(s): {0}" -f ($ids -join ','))
      } catch {
        Write-Warning ("[rogue-sweep] Stop-Process failed: {0}" -f $_.Exception.Message)
      }
    }

    Start-Sleep -Seconds 2
  }

  throw 'Rogue LVCompare/LabVIEW processes remain after retry attempts.'
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
        if ($IncludeIntegration) {
          $args += 'include'
        } else {
          $args += 'exclude'
        }
        $args += '-CleanLabVIEW'
        $args += '-CleanAfter'
        $args += '-DetectLeaks'
        $args += '-KillLeaks'
        $args += '-FailOnLeaks'
        $args += '-LeakGraceSeconds'
        $args += '5'
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
    Invoke-BackboneStep -Name 'PrePush-Checks.ps1' -Action {
      & pwsh '-NoLogo' '-NoProfile' '-File' (Join-Path $repoRoot 'tools' 'PrePush-Checks.ps1')
    }
  } else {
    Write-Host "Skipping PrePush-Checks as requested." -ForegroundColor Yellow
  }

  Invoke-BackboneStep -Name 'LabVIEW cleanup buffer' -Action {
    $waitScript = Join-Path $repoRoot 'tools' 'Agent-Wait.ps1'
    $waitStarted = $false
    $waitSeconds = 2
    if (Test-Path -LiteralPath $waitScript -PathType Leaf) {
      try {
        . $waitScript
        if (Get-Command -Name 'Start-AgentWait' -ErrorAction SilentlyContinue) {
          try {
            Start-AgentWait -Reason 'labview shutdown buffer' -ExpectedSeconds $waitSeconds | Out-Null
            $waitStarted = $true
          } catch {}
        }
      } catch {}
    }
    Start-Sleep -Seconds $waitSeconds
    if ($waitStarted -and (Get-Command -Name 'End-AgentWait' -ErrorAction SilentlyContinue)) {
      try { End-AgentWait | Out-Null } catch {}
    }

    $closeScript = Join-Path $repoRoot 'tools' 'Close-LabVIEW.ps1'
    if (Test-Path -LiteralPath $closeScript -PathType Leaf) {
      $closeExit = $null
      for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
          & pwsh '-NoLogo' '-NoProfile' '-File' $closeScript | Out-Null
          $closeExit = $LASTEXITCODE
        } catch {
          $closeExit = -1
          Write-Warning ("Backbone cleanup: Close-LabVIEW.ps1 failed (attempt {0}): {1}" -f ($attempt + 1), $_.Exception.Message)
        }
        if ($closeExit -eq 0) { break }
        Start-Sleep -Seconds 1
      }
    }

    $labviewProcs = @()
    try { $labviewProcs = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue) } catch {}
    if ($labviewProcs.Count -gt 0) {
      try {
        Stop-Process -Id $labviewProcs.Id -Force -ErrorAction Stop
        Write-Warning ("Backbone cleanup: forced LabVIEW.exe termination (PID(s) {0})." -f ($labviewProcs.Id -join ','))
      } catch {
        Write-Warning ("Backbone cleanup: Stop-Process failed: {0}" -f $_.Exception.Message)
      }
    }
  } -SkipWhenDryRun

  Invoke-BackboneStep -Name 'Rogue LV sweep' -Action {
    Invoke-RogueSweep -RepoRoot $repoRoot -LookBackSeconds 900 -MaxAttempts 3 | Out-Null
  } -SkipWhenDryRun

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
