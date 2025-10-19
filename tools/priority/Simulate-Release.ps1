#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Execute,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Npm {
  param([string]$Script)
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot launch npm wrapper.'
  }
  $wrapperPath = Join-Path (Resolve-Path '.').Path 'tools/npm/run-script.mjs'
  if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
    throw "npm wrapper not found at $wrapperPath"
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.ArgumentList.Add($wrapperPath)
  $psi.ArgumentList.Add($Script)
  $psi.WorkingDirectory = (Resolve-Path '.').Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Warning $stderr.TrimEnd() }
  if ($proc.ExitCode -ne 0) {
    throw "node tools/npm/run-script.mjs $Script exited with code $($proc.ExitCode)"
  }
}

function Invoke-SemVerCheck {
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot run SemVer check.'
  }
  $scriptPath = Join-Path (Resolve-Path '.').Path 'tools/priority/validate-semver.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "SemVer script not found at $scriptPath"
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.ArgumentList.Add($scriptPath)
  $psi.WorkingDirectory = (Resolve-Path '.').Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if ($stderr) { Write-Warning $stderr.TrimEnd() }
  $result = $null
  if ($stdout) {
    try { $result = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop } catch {}
  }
  return [pscustomobject]@{
    ExitCode = $proc.ExitCode
    Result = $result
    Raw = $stdout.Trim()
  }
}

function Write-ReleaseSummary {
  param([pscustomobject]$SemVer)
  $handoffDir = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff'
  New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
  $result = $null
  if ($null -ne $SemVer -and $SemVer.PSObject.Properties.Name -contains 'Result') {
    $result = $SemVer.Result
  }
  $version = '(unknown)'
  $valid = $false
  $issues = @()
  $checkedAt = (Get-Date).ToString('o')
  if ($null -ne $result) {
    if ($result.PSObject.Properties.Name -contains 'version' -and $result.version) {
      $version = [string]$result.version
    }
    if ($result.PSObject.Properties.Name -contains 'valid') {
      $valid = [bool]$result.valid
    }
    if ($result.PSObject.Properties.Name -contains 'issues' -and $null -ne $result.issues) {
      $issues = @($result.issues)
    }
    if ($result.PSObject.Properties.Name -contains 'checkedAt' -and $null -ne $result.checkedAt) {
      if ($result.checkedAt -is [datetime]) {
        $checkedAt = $result.checkedAt.ToString('o')
      } else {
        $checkedAt = [string]$result.checkedAt
      }
    }
  }
  $summary = [ordered]@{
    schema = 'agent-handoff/release-v1'
    version = $version
    valid = $valid
    issues = $issues
    checkedAt = $checkedAt
  }
  $summaryPath = Join-Path $handoffDir 'release-summary.json'
  $previous = $null
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    try { $previous = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
  }
  ($summary | ConvertTo-Json -Depth 4) | Out-File -FilePath $summaryPath -Encoding utf8
  if ($previous) {
    $changed = ($previous.version -ne $summary.version) -or ($previous.valid -ne $summary.valid)
    if ($changed) {
      Write-Host ("[release] SemVer state changed {0}/{1} -> {2}/{3}" -f $previous.version,$previous.valid,$summary.version,$summary.valid) -ForegroundColor Cyan
    }
  }
  return $summary
}

Write-Host '[release] Refreshing standing priority snapshot…'
Invoke-Npm -Script 'priority:sync'

Write-Host '[release] Validating SemVer version…'
$semverOutcome = Invoke-SemVerCheck
$releaseSummary = Write-ReleaseSummary -SemVer $semverOutcome
Write-Host ('[release] Version: {0} (valid: {1})' -f $releaseSummary.version, $releaseSummary.valid)
if (-not $releaseSummary.valid) {
  foreach ($issue in $releaseSummary.issues) { Write-Warning $issue }
  throw "SemVer validation failed for version $($releaseSummary.version)"
}

$routerPath = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/issue/router.json'
if (-not (Test-Path -LiteralPath $routerPath -PathType Leaf)) {
  throw "Router plan not found at $routerPath. Run priority:sync first."
}

$router = Get-Content -LiteralPath $routerPath -Raw | ConvertFrom-Json -ErrorAction Stop
$actions = @($router.actions | Sort-Object priority)

Write-Host '[release] Planned actions:' -ForegroundColor Cyan
foreach ($action in $actions) {
  Write-Host ("  - {0} (priority {1})" -f $action.key, $action.priority)
  if ($action.scripts) {
    foreach ($script in $action.scripts) {
      Write-Host ("      script: {0}" -f $script)
    }
  }
}

$hasRelease = $actions | Where-Object { $_.key -eq 'release:prep' }
if ($hasRelease) {
  Write-Host '[release] Running release preparation scripts…' -ForegroundColor Cyan
  foreach ($script in $hasRelease.scripts) {
    Write-Host ("[release] Executing: {0}" -f $script)
    & pwsh -NoLogo -NoProfile -Command $script
  }
} else {
  Write-Host '[release] No release-specific actions found in router.' -ForegroundColor Yellow
}

if ($Execute -and $hasRelease) {
  Write-Host '[release] Invoking Branch-Orchestrator with execution…' -ForegroundColor Cyan
  & pwsh -NoLogo -NoProfile -File (Join-Path (Resolve-Path '.').Path 'tools/Branch-Orchestrator.ps1') -Execute
} elseif (-not $DryRun -and $hasRelease) {
  Write-Host '[release] Running branch orchestrator in dry-run mode (default)…'
  & pwsh -NoLogo -NoProfile -File (Join-Path (Resolve-Path '.').Path 'tools/Branch-Orchestrator.ps1') -DryRun
} else {
  Write-Host '[release] Branch orchestrator skipped.' -ForegroundColor Yellow
}

Write-Host '[release] Simulation complete.'
