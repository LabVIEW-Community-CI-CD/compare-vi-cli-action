<#!
.SYNOPSIS
  Quick local verification of Compare VI action outputs (seconds + nanoseconds) without running full Pester.
.DESCRIPTION
  Creates temporary placeholder .vi files (unless explicit paths provided), invokes Invoke-CompareVI and
  prints a concise output block similar to GITHUB_OUTPUT plus a timing summary. Does not fail on diff.
.PARAMETER Base
  Path to base VI; if omitted a temp file is created.
.PARAMETER Head
  Path to head VI; if omitted a temp file is created (different file => diff exit code 1).
.PARAMETER Same
  Switch: if set, uses the same file for Base and Head (expect diff=false, exitCode 0).
.PARAMETER ShowSummary
  Switch: if set, renders a minimal markdown-like summary block.
.EXAMPLE
  ./tools/Quick-VerifyCompare.ps1
.EXAMPLE
  ./tools/Quick-VerifyCompare.ps1 -Same -ShowSummary
.EXAMPLE
  ./tools/Quick-VerifyCompare.ps1 -Base path\to\A.vi -Head path\to\B.vi
#>
[CmdletBinding()] param(
  [string]$Base,
  [string]$Head,
  [switch]$Same,
  [switch]$ShowSummary
)

$ErrorActionPreference = 'Stop'
set-strictmode -version latest

# Load CompareVI module
Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'CompareVI.psm1') -Force

$cleanup = @()
try {
  if (-not $Base) {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("comparevi-base-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $Base = Join-Path $tempDir 'VI1.vi'
    New-Item -ItemType File -Force -Path $Base | Out-Null
    $cleanup += $tempDir
  }
  if ($Same) {
    $Head = $Base
  } elseif (-not $Head) {
    $tempDir2 = Join-Path ([IO.Path]::GetTempPath()) ("comparevi-head-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tempDir2 | Out-Null
    $Head = Join-Path $tempDir2 'VI2.vi'
    New-Item -ItemType File -Force -Path $Head | Out-Null
    $cleanup += $tempDir2
  }

  # Mock CLI if canonical path missing (non-fatal) by faking Resolve-Cli
  $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  $haveCli = Test-Path -LiteralPath $canonical -PathType Leaf
  if (-not $haveCli) {
    function Resolve-Cli { param($Explicit) return $canonical }
    Write-Host "NOTE: Canonical LVCompare.exe not found; using mocked Resolve-Cli for timing demo" -ForegroundColor Yellow
  }

  $forceSame = $Same.IsPresent
  # Executor: return 0 if explicitly forced (-Same) OR paths resolve identical; else 1
  $exec = {
    param($cli,$b,$h,$compareArgs)
    if ($script:forceSame) { return 0 }
    $bResolved = try { (Resolve-Path -LiteralPath $b -ErrorAction Stop).Path } catch { $b }
    $hResolved = try { (Resolve-Path -LiteralPath $h -ErrorAction Stop).Path } catch { $h }
    if ($bResolved -eq $hResolved) { return 0 } else { return 1 }
  }
  # Expose flag inside script scope for closure
  $script:forceSame = $forceSame

  $result = Invoke-CompareVI -Base $Base -Head $Head -FailOnDiff:$false -Executor $exec

  $diffLower = if ($result.Diff) { 'true' } else { 'false' }

  Write-Host "=== Quick Verify Compare ===" -ForegroundColor Cyan
  Write-Host ("Base: {0}" -f $result.Base)
  Write-Host ("Head: {0}" -f $result.Head)
  Write-Host ("ExitCode: {0}" -f $result.ExitCode)
  Write-Host ("Diff: {0}" -f $diffLower)
  Write-Host ("compareDurationSeconds: {0}" -f $result.CompareDurationSeconds)
  Write-Host ("compareDurationNanoseconds: {0}" -f $result.CompareDurationNanoseconds)
  $ms = [math]::Round([double]$result.CompareDurationSeconds * 1000,2)
  Write-Host ("Combined: {0}s ({1} ms)" -f $result.CompareDurationSeconds, $ms)

  if ($ShowSummary) {
    Write-Host ""
    Write-Host "--- Summary Block ---" -ForegroundColor DarkCyan
    "### Compare VI (Quick Verify)" | Write-Host
    "- Diff: $diffLower" | Write-Host
    "- Seconds: $($result.CompareDurationSeconds)" | Write-Host
    "- Nanoseconds: $($result.CompareDurationNanoseconds)" | Write-Host
    "- Combined: $($result.CompareDurationSeconds)s ($ms ms)" | Write-Host
  }

  Write-Host "Status: SUCCESS" -ForegroundColor Green
}
catch {
  Write-Host "Status: FAILURE - $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
finally {
  foreach ($p in $cleanup) { if (Test-Path $p) { Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue } }
}
