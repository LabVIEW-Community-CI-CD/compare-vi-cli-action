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
$script:autoTestPlan = $null

function Write-LabViewEnvSnapshot {
  param(
    [string]$RepoRoot,
    [string]$OutputPath
  )

  $keys = @(
    'CLEAN_LABVIEW',
    'CLEAN_LVCOMPARE',
    'LABVIEW_CLEANUP',
    'LVCI_COMPARE_POLICY',
    'LVCI_COMPARE_MODE',
    'FAST_PESTER'
  )

  $snapshot = [ordered]@{
    schema      = 'labview-env-snapshot/v1'
    generatedAt = (Get-Date).ToString('o')
    repoRoot    = $RepoRoot
    values      = @{}
  }

  Write-Host '[pester] LabVIEW/LVCompare environment snapshot:' -ForegroundColor DarkGray
  foreach ($key in $keys) {
    $value = [System.Environment]::GetEnvironmentVariable($key)
    $display = if ($null -eq $value) { '<unset>' } elseif ($value -eq '') { '""' } else { $value }
    Write-Host ("  {0} = {1}" -f $key, $display) -ForegroundColor DarkGray
    $snapshot.values[$key] = $value
  }

  if ($OutputPath) {
    $outputDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $snapshot | ConvertTo-Json -Depth 4 | Out-File -FilePath $OutputPath -Encoding utf8
  }

  return $snapshot
}

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

  Invoke-BackboneStep -Name 'Snapshot work in progress' -SkipWhenDryRun -Action {
    & pwsh '-NoLogo' '-NoProfile' '-File' (Join-Path $repoRoot 'tools' 'Save-WorkInProgress.ps1') '-RepositoryRoot' $repoRoot '-Name' 'local-backbone'
  }

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

  Invoke-BackboneStep -Name 'Prepare standing commit' -SkipWhenDryRun -Action {
    $args = @(
      '-NoLogo', '-NoProfile',
      '-File', (Join-Path $repoRoot 'tools' 'Prepare-StandingCommit.ps1'),
      '-RepositoryRoot', $repoRoot,
      '-AutoCommit'
    )
    & pwsh @args
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
      $planPath = Join-Path $repoRoot 'tests/results/_agent/commit-plan.json'
      if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        try {
          $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -ErrorAction Stop
          if ($plan.tests) {
            $script:autoTestPlan = $plan.tests
          }
        } catch {
          Write-Warning ("Failed to parse commit plan summary: {0}" -f $_.Exception.Message)
        }
      }
    }
    $LASTEXITCODE = $exit
  }

  Invoke-BackboneStep -Name 'Post-commit automation' -SkipWhenDryRun -Action {
    $args = @(
      '-NoLogo','-NoProfile',
      '-File',(Join-Path $repoRoot 'tools' 'After-CommitActions.ps1'),
      '-RepositoryRoot',$repoRoot,
      '-Push',
      '-CreatePR',
      '-CloseIssue'
    )
    if ($PushTarget) {
      $args += '-PushTarget'
      $args += $PushTarget
    }
    & pwsh @args
  }

  $autoPlan = $script:autoTestPlan
  $shouldRunPester = -not $SkipPester
  $testDecisionLabel = $null
  $testDecisionReasons = @()
  if ($shouldRunPester -and $autoPlan) {
    if ($autoPlan.PSObject.Properties['decision']) {
      $testDecisionLabel = $autoPlan.decision
    }
    if ($autoPlan.PSObject.Properties['reasons'] -and $autoPlan.reasons) {
      $testDecisionReasons = @($autoPlan.reasons)
    }
    switch ($testDecisionLabel) {
      'skip'  { $shouldRunPester = $false }
      'fresh' { $shouldRunPester = $false }
      default { }
    }
  }

  if (-not $SkipPester) {
    $labViewEnvPath = Join-Path $repoRoot 'tests/results/_agent/labview-env.json'
    Write-LabViewEnvSnapshot -RepoRoot $repoRoot -OutputPath $labViewEnvPath

    if (-not $shouldRunPester) {
      $label = if ($testDecisionLabel) { $testDecisionLabel } else { 'n/a' }
      Write-Host ("Tests marked as '{0}' by commit plan; skipping Pester run." -f $label) -ForegroundColor Yellow
      foreach ($reason in $testDecisionReasons) {
        Write-Host ("  reason: {0}" -f $reason) -ForegroundColor Gray
      }
    } else {
      if ($testDecisionLabel) {
        Write-Host ("Tests decision '{0}' -> running suite." -f $testDecisionLabel) -ForegroundColor Cyan
      }
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
    }
  } else {
    Write-Host "Skipping Pester run as requested." -ForegroundColor Yellow
  }

  Invoke-BackboneStep -Name 'Rogue LV cleanup' -SkipWhenDryRun -Action {
    $args = @(
      '-NoLogo','-NoProfile',
      '-File',(Join-Path $repoRoot 'tools' 'Clean-RogueLV.ps1'),
      '-ResultsDir',(Join-Path $repoRoot 'tests' 'results')
    )
    & pwsh @args
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
