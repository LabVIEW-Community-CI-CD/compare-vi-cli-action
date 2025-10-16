#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$VerboseHooks,
  [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Npm {
  param(
    [Parameter(Mandatory=$true)][string]$Script,
    [switch]$AllowFailure
  )

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

  if ($proc.ExitCode -ne 0 -and -not $AllowFailure) {
    throw "node tools/npm/run-script.mjs $Script exited with code $($proc.ExitCode)"
  }
}

function Invoke-SemVerCheck {
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    Write-Warning 'node not found; skipping semver check.'
    return $null
  }

  $scriptPath = Join-Path (Resolve-Path '.').Path 'tools/priority/validate-semver.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Warning "SemVer script not found at $scriptPath"
    return $null
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

  $json = $null
  if ($stdout) { $json = $stdout.Trim() }

  $result = $null
  if ($json) {
    try { $result = $json | ConvertFrom-Json -ErrorAction Stop } catch { Write-Warning 'Failed to parse semver JSON output.' }
  }

  return [pscustomobject]@{
    ExitCode = $proc.ExitCode
    Raw = $json
    Result = $result
  }
}

function Write-ReleaseSummary {
  param([pscustomobject]$SemVerResult)

  $handoffDir = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff'
  New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

  $result = $SemVerResult?.Result
  $summary = [ordered]@{
    schema   = 'agent-handoff/release-v1'
    version  = $result?.version ?? '(unknown)'
    valid    = [bool]($result?.valid)
    issues   = @()
    checkedAt = $result?.checkedAt ?? (Get-Date).ToString('o')
  }

  if ($result?.issues) {
    $summary.issues = @($result.issues)
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
      Write-Host ("[bootstrap] SemVer state changed {0}/{1} -> {2}/{3}" -f $previous.version,$previous.valid,$summary.version,$summary.valid) -ForegroundColor Cyan
    }
  }

  return $summary
}

Write-Host '[bootstrap] Detecting hook plane…'
Invoke-Npm -Script 'hooks:plane' -AllowFailure

Write-Host '[bootstrap] Running hook preflight…'
Invoke-Npm -Script 'hooks:preflight' -AllowFailure

if ($VerboseHooks) {
  Write-Host '[bootstrap] Running hook parity diff…'
  Invoke-Npm -Script 'hooks:multi' -AllowFailure:$true
  Write-Host '[bootstrap] Validating hook summary schema…'
  Invoke-Npm -Script 'hooks:schema' -AllowFailure:$true
}

if (-not $PreflightOnly) {
  Write-Host '[bootstrap] Syncing standing priority snapshot…'
  Invoke-Npm -Script 'priority:sync' -AllowFailure:$true
  Write-Host '[bootstrap] Showing router plan…'
  Invoke-Npm -Script 'priority:show' -AllowFailure:$true

  Write-Host '[bootstrap] Validating SemVer version…'
  $semverOutcome = Invoke-SemVerCheck
  if ($semverOutcome -and $semverOutcome.Result) {
    Write-Host ('[bootstrap] Version: {0} (valid: {1})' -f $semverOutcome.Result.version, $semverOutcome.Result.valid)
    $summary = Write-ReleaseSummary -SemVerResult $semverOutcome
    if (-not $semverOutcome.Result.valid) {
      foreach ($issue in $summary.issues) { Write-Warning $issue }
    }
  } else {
    Write-Warning '[bootstrap] SemVer check skipped; writing placeholder summary.'
    $placeholder = [pscustomobject]@{
      Result = [pscustomobject]@{
        version = '(unknown)'
        valid = $false
        issues = @('SemVer check skipped during bootstrap')
        checkedAt = (Get-Date).ToString('o')
      }
    }
    Write-ReleaseSummary -SemVerResult $placeholder | Out-Null
  }
}

Write-Host '[bootstrap] Bootstrapping complete.'
