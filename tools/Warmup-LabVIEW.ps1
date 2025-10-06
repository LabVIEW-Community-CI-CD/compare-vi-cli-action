<#
.SYNOPSIS
  Best-effort LabVIEW warmup for self-hosted Windows runners.

.DESCRIPTION
  Ensures a LabVIEW.exe instance is started before tests/compare work begins by
  briefly launching LVCompare.exe (canonical path) against two VIs, then
  terminating only LVCompare.exe while leaving LabVIEW.exe running.

  No-op when LabVIEW is already running or when LVCompare is not present.

.PARAMETER BaseVi
  Optional base VI path. Defaults to repo-root VI1.vi when present.

.PARAMETER HeadVi
  Optional head VI path. Defaults to repo-root VI2.vi when present.

.PARAMETER TimeoutSeconds
  Time to wait for LabVIEW to appear after spawning LVCompare. Default 15.

.PARAMETER KillDelaySeconds
  Delay before stopping LVCompare (to allow LabVIEW to load). Default 3.
#>
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [int]$TimeoutSeconds = 15,
  [int]$KillDelaySeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-StepSummaryLine([string]$line) {
  if ($env:GITHUB_STEP_SUMMARY) { $line | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
}

if ($IsWindows -ne $true) { return }

# If LabVIEW already running, bail out quickly
try {
  $existing = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
  if ($existing.Count -gt 0) {
    Write-Host "Warmup: LabVIEW already running (PID(s): $($existing.Id -join ','))"
    Write-StepSummaryLine "- Warmup: LabVIEW already running (PID(s): $($existing.Id -join ','))"
    return
  }
} catch {}

$repoRoot = (Get-Location).Path
if (-not $BaseVi) { $BaseVi = Join-Path $repoRoot 'VI1.vi' }
if (-not $HeadVi) { $HeadVi = Join-Path $repoRoot 'VI2.vi' }

$cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
  Write-Host "Warmup: LVCompare not found at canonical path; skipping." -ForegroundColor Yellow
  Write-StepSummaryLine "- Warmup: LVCompare.exe not found; skipped"
  return
}

if (-not (Test-Path -LiteralPath $BaseVi)) { Write-Host "Warmup: Base VI not found: $BaseVi" -ForegroundColor Yellow; return }
if (-not (Test-Path -LiteralPath $HeadVi)) { Write-Host "Warmup: Head VI not found: $HeadVi" -ForegroundColor Yellow; return }

Write-Host "Warmup: starting LVCompare to spawn LabVIEW..."
Write-StepSummaryLine "- Warmup: starting LVCompare to spawn LabVIEW"

# Start LVCompare normally (UI allowed). Do not suppress UI; do not redirect.
$p = Start-Process -FilePath $cli -ArgumentList @($BaseVi,$HeadVi) -PassThru

# Poll for LabVIEW to appear
$deadline = (Get-Date).AddSeconds([Math]::Max(1,$TimeoutSeconds))
do {
  Start-Sleep -Milliseconds 200
  try { $lv = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue) } catch { $lv = @() }
  if ($lv.Count -gt 0) { break }
} while ((Get-Date) -lt $deadline)

if ($lv.Count -gt 0) {
  Write-Host "Warmup: LabVIEW started (PID(s): $($lv.Id -join ','))"
  Write-StepSummaryLine "- Warmup: LabVIEW started (PID(s): $($lv.Id -join ','))"
} else {
  Write-Host "Warmup: LabVIEW did not start within timeout ($TimeoutSeconds s)." -ForegroundColor Yellow
  Write-StepSummaryLine "- Warmup: LabVIEW did not start within timeout ($TimeoutSeconds s)"
}

# Give LVCompare a short window then stop only LVCompare (leave LabVIEW)
if ($KillDelaySeconds -gt 0) { Start-Sleep -Seconds $KillDelaySeconds }
try {
  if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  else { Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} } }
  Write-Host "Warmup: LVCompare stopped; LabVIEW remains running."
  Write-StepSummaryLine "- Warmup: LVCompare stopped; LabVIEW remains running"
} catch {
  Write-Host "Warmup: failed to stop LVCompare (continuing): $($_.Exception.Message)" -ForegroundColor Yellow
}

