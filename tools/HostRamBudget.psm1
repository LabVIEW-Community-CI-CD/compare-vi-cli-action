Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CompareVIOptionalValuePresent {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $false
  }

  if ($Value.PSObject.Properties['HasValue']) {
    return [bool]$Value.HasValue
  }

  return $true
}

function Get-CompareVIOptionalValue {
  param([AllowNull()][object]$Value)

  if (-not (Test-CompareVIOptionalValuePresent -Value $Value)) {
    return $null
  }

  if ($Value.PSObject.Properties['Value']) {
    return $Value.Value
  }

  return $Value
}

function Resolve-CompareVIHostRamBudgetReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('light', 'medium', 'heavy', 'ni-linux-flag-combination', 'windows-mirror-heavy')]
    [string]$TargetProfile = 'heavy',
    [ValidateRange(1, 64)]
    [int]$MinimumParallelism = 1,
    [Nullable[long]]$TotalBytes = $null,
    [Nullable[long]]$FreeBytes = $null,
    [Nullable[int]]$CpuParallelism = $null
  )

  $budgetScriptPath = Join-Path $PSScriptRoot 'priority' 'host-ram-budget.mjs'
  if (-not (Test-Path -LiteralPath $budgetScriptPath -PathType Leaf)) {
    throw ("Host RAM budget helper not found: {0}" -f $budgetScriptPath)
  }

  $budgetArgs = [System.Collections.Generic.List[string]]::new()
  [void]$budgetArgs.Add($budgetScriptPath)
  [void]$budgetArgs.Add('--target-profile')
  [void]$budgetArgs.Add($TargetProfile)
  [void]$budgetArgs.Add('--output')
  [void]$budgetArgs.Add($OutputPath)
  [void]$budgetArgs.Add('--minimum-parallelism')
  [void]$budgetArgs.Add([string]$MinimumParallelism)
  if (Test-CompareVIOptionalValuePresent -Value $TotalBytes) {
    [void]$budgetArgs.Add('--total-bytes')
    [void]$budgetArgs.Add([string](Get-CompareVIOptionalValue -Value $TotalBytes))
  }
  if (Test-CompareVIOptionalValuePresent -Value $FreeBytes) {
    [void]$budgetArgs.Add('--free-bytes')
    [void]$budgetArgs.Add([string](Get-CompareVIOptionalValue -Value $FreeBytes))
  }
  if (Test-CompareVIOptionalValuePresent -Value $CpuParallelism) {
    [void]$budgetArgs.Add('--cpu-parallelism')
    [void]$budgetArgs.Add([string](Get-CompareVIOptionalValue -Value $CpuParallelism))
  }

  Push-Location $RepoRoot
  try {
    $budgetArgArray = $budgetArgs.ToArray()
    & node @budgetArgArray | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw ("host-ram-budget helper exited with code {0}" -f $LASTEXITCODE)
    }
  } finally {
    Pop-Location | Out-Null
  }

  if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw ("Host RAM budget helper did not emit a report: {0}" -f $OutputPath)
  }

  $report = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json -Depth 20
  if (-not $report.selectedProfile -or -not $report.selectedProfile.PSObject.Properties['recommendedParallelism']) {
    throw ("Host RAM budget report missing selected profile recommendation: {0}" -f $OutputPath)
  }

  return [pscustomobject]@{
    path = $OutputPath
    report = $report
  }
}

function New-CompareVISerialHostRamBudgetDecision {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$BudgetReport,
    [Parameter(Mandatory)][string]$BudgetPath,
    [ValidateRange(0, 64)]
    [int]$RequestedParallelism = 0,
    [ValidateRange(1, 64)]
    [int]$ActualParallelism = 1,
    [string]$ReasonWhenParallelEligible = 'serial-execution-contract'
  )

  if (-not $BudgetReport.selectedProfile -or -not $BudgetReport.selectedProfile.PSObject.Properties['recommendedParallelism']) {
    throw 'Budget report is missing selectedProfile.recommendedParallelism.'
  }

  $recommendedParallelism = [int]$BudgetReport.selectedProfile.recommendedParallelism
  $decisionSource = 'host-ram-budget'
  if ($RequestedParallelism -gt 0) {
    $recommendedParallelism = [int]$RequestedParallelism
    $decisionSource = 'explicit-override'
  }

  if ($ActualParallelism -lt 1) {
    $ActualParallelism = 1
  }

  $reason = $ReasonWhenParallelEligible
  if ($ActualParallelism -ge 2) {
    $reason = 'parallel-execution'
  } elseif ($recommendedParallelism -le 1) {
    $reason = if ($BudgetReport.selectedProfile.PSObject.Properties['reasons'] -and @($BudgetReport.selectedProfile.reasons).Count -gt 0) {
      [string]::Join(', ', @($BudgetReport.selectedProfile.reasons | ForEach-Object { [string]$_ }))
    } else {
      'deterministic-floor'
    }
  }

  return [pscustomobject]@{
    path = $BudgetPath
    targetProfile = [string]$BudgetReport.selectedProfile.id
    requestedParallelism = [int]$RequestedParallelism
    recommendedParallelism = [int]$recommendedParallelism
    actualParallelism = [int]$ActualParallelism
    decisionSource = $decisionSource
    reason = $reason
    executionMode = if ($ActualParallelism -ge 2) { 'parallel' } else { 'serial' }
    parallelExecutionSupported = ($ActualParallelism -ge 2)
    report = $BudgetReport
  }
}

Export-ModuleMember -Function Resolve-CompareVIHostRamBudgetReport, New-CompareVISerialHostRamBudgetDecision
