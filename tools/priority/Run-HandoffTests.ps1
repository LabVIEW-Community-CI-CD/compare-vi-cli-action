#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NpmCommand {
  param(
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string]$NodePath,
    [Parameter(Mandatory=$true)][string]$WrapperPath
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $NodePath
  $psi.ArgumentList.Add($WrapperPath)
  $psi.ArgumentList.Add($Script)
  $psi.WorkingDirectory = (Resolve-Path '.').Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $startTime = Get-Date
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $endTime = Get-Date

  return [pscustomobject]@{
    command     = "node tools/npm/run-script.mjs $Script"
    exitCode    = $proc.ExitCode
    stdout      = $stdout.TrimEnd()
    stderr      = $stderr.TrimEnd()
    startedAt   = $startTime.ToString('o')
    completedAt = $endTime.ToString('o')
    durationMs  = [int][Math]::Round((New-TimeSpan -Start $startTime -End $endTime).TotalMilliseconds)
  }
$nodePath = (Get-Command node -ErrorAction SilentlyContinue)?.Source
$wrapperPath = Join-Path (Resolve-Path '.').Path 'tools/npm/run-script.mjs'

if (-not $nodePath -or -not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
  Write-Warning '[handoff-tests] node or npm wrapper not found; writing error summary.'
}

$results = @()
$notes = @()

if ($nodePath -and (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
  $scripts = @('priority:test','hooks:test','semver:check')
  foreach ($script in $scripts) {
    try {
      $results += Invoke-NpmCommand -Script $script -NodePath $nodePath -WrapperPath $wrapperPath
    } catch {
      $notes += ("Invocation for node tools/npm/run-script.mjs {0} failed: {1}" -f $script, $_.Exception.Message)
      $results += [pscustomobject]@{
        command     = "node tools/npm/run-script.mjs $script"
        exitCode    = -1
        stdout      = ''
        stderr      = ("Invocation failed: {0}" -f $_.Exception.Message)
        startedAt   = (Get-Date).ToString('o')
        completedAt = (Get-Date).ToString('o')
        durationMs  = 0
      }
      break
    }
  }
}

$handoffDir = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff'
New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
$summaryPath = Join-Path $handoffDir 'test-summary.json'

$failureEntries = @($results | Where-Object { $_.exitCode -ne 0 })
$failureCount = $failureEntries.Count
$status = if (-not $nodePath -or -not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
  'error'
} elseif ($results.Count -eq 0) {
  'skipped'
} elseif ($failureCount -gt 0) {
  'failed'
} else {
  'passed'
}

$summary = [ordered]@{
  schema       = 'agent-handoff/test-results@v1'
  generatedAt  = (Get-Date).ToString('o')
  status       = $status
  total        = $results.Count
  failureCount = $failureCount
  results      = $results
  runner       = [ordered]@{
    name        = $env:RUNNER_NAME
    os          = $env:RUNNER_OS
    arch        = $env:RUNNER_ARCH
    job         = $env:GITHUB_JOB
    imageOS     = $env:ImageOS
    imageVersion= $env:ImageVersion
  }
}

if (-not $nodePath) {
  $notes += 'node executable not found in PATH'
}
if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
  $notes += 'npm wrapper missing under tools/npm/run-script.mjs'
}

$notes = @($notes | Where-Object { $_ })
if ($notes.Count -gt 0) {
  $summary.notes = $notes
}

($summary | ConvertTo-Json -Depth 6) | Out-File -FilePath $summaryPath -Encoding utf8

Write-Host ("[handoff-tests] status={0} total={1} failures={2} -> {3}" -f $status, $summary.total, $failureCount, $summaryPath) -ForegroundColor Cyan

if (-not $nodePath -or -not (Test-Path -LiteralPath $wrapperPath -PathType Leaf) -or $failureCount -gt 0) {
  exit 1
}
