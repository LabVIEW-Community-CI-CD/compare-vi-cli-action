<#$
.SYNOPSIS
  Stubbed smoke test for the TestStand compare harness CLI.

.DESCRIPTION
  Creates a temporary workspace with stub implementations of the LabVIEW warmup and
  LVCompare tooling, then executes the Node wrapper (`npm run teststand:compare`)
  pointing at that workspace. Verifies that `session-index.json` is produced and,
  when requested, appends a short summary to the GitHub Step Summary.

.PARAMETER ResultsRoot
  Directory where the captured session will be copied (default: temporary folder).

.PARAMETER AppendSummary
  When set, append a summary block to `$GITHUB_STEP_SUMMARY` if available.
#>
[CmdletBinding()]
param(
  [string]$ResultsRoot,
  [switch]$AppendSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$defaultTarget = if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'teststand-harness-smoke' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'teststand-harness-smoke' }
if (-not $ResultsRoot) { $ResultsRoot = $defaultTarget }

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("teststand-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace | Out-Null

try {
  $toolsDir = Join-Path $workspace 'tools'
  New-Item -ItemType Directory -Path $toolsDir | Out-Null

  Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'TestStand-CompareHarness.ps1') -Destination (Join-Path $toolsDir 'TestStand-CompareHarness.ps1')

  $warmupStub = @'
param(
  [string]$LabVIEWPath,
  [string]$JsonLogPath
)
if ($JsonLogPath) {
  $dir = Split-Path -Parent $JsonLogPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  "{\"type\":\"warmup\",\"schema\":\"stub\"}" | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}
exit 0
'@
  $warmupPath = Join-Path $toolsDir 'Warmup-LabVIEWRuntime.ps1'
  Set-Content -LiteralPath $warmupPath -Value $warmupStub -Encoding UTF8

  $compareStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [Alias("LabVIEWPath")]
  [string]$LabVIEWExePath,
  [Alias("LVCompareExePath")]
  [string]$LVComparePath,
  [string]$OutputDir,
  [switch]$RenderReport,
  [string]$JsonLogPath
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if ($JsonLogPath) {
  $dir = Split-Path -Parent $JsonLogPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  "{\"type\":\"compare\",\"schema\":\"stub\"}" | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}
$capture = [ordered]@{
  schema   = 'lvcompare-capture-v1'
  exitCode = 1
  seconds  = 0.1
  command  = 'stub lvcompare'
}
$capture | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
'report' | Set-Content -LiteralPath (Join-Path $OutputDir 'compare-report.html') -Encoding utf8
exit 1
'@
  Set-Content -LiteralPath (Join-Path $toolsDir 'Invoke-LVCompare.ps1') -Value $compareStub -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $toolsDir 'Close-LVCompare.ps1') -Value 'param() exit 0' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $toolsDir 'Close-LabVIEW.ps1') -Value 'param() exit 0' -Encoding UTF8

  Set-Content -LiteralPath (Join-Path $workspace 'VI1.vi') -Value '' -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $workspace 'VI2.vi') -Value '' -Encoding ASCII

  $outputRoot = Join-Path $workspace 'session'
  $node = (Get-Command node -ErrorAction Stop).Source
  $cli = Join-Path $repoRoot 'dist' 'teststand' 'run-harness.js'
  if (-not (Test-Path -LiteralPath $cli)) { throw "CLI not built at $cli. Run 'npm run build' first." }

  $arguments = @($cli,
    '--base', (Join-Path $workspace 'VI1.vi'),
    '--head', (Join-Path $workspace 'VI2.vi'),
    '--repo-root', $workspace,
    '--output', $outputRoot,
    '--render-report')

  $process = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $repoRoot -PassThru -NoNewWindow -Wait
  $exitCode = $process.ExitCode

  $sessionIndex = Join-Path $outputRoot 'session-index.json'
  if (-not (Test-Path -LiteralPath $sessionIndex)) { throw "session-index.json not produced at $sessionIndex" }
  $session = Get-Content -LiteralPath $sessionIndex -Raw | ConvertFrom-Json -ErrorAction Stop

  $targetRoot = if ([System.IO.Path]::IsPathRooted($ResultsRoot)) { $ResultsRoot } else { Join-Path $repoRoot $ResultsRoot }
  if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null }
  $targetSession = Join-Path $targetRoot 'session'
  if (Test-Path -LiteralPath $targetSession) { Remove-Item -LiteralPath $targetSession -Recurse -Force }
  Copy-Item -LiteralPath $outputRoot -Destination $targetSession -Recurse

  if ($AppendSummary -and $env:GITHUB_STEP_SUMMARY) {
    $lines = @('### TestStand Harness Smoke','')
    $lines += ('- CLI exit code: {0}' -f $exitCode)
    $diffFlag = if ($session.outcome -and $session.outcome.diff -ne $null) { $session.outcome.diff } else { '<n/a>' }
    $lines += ('- Diff detected (stub): {0}' -f $diffFlag)
    $lines += ('- Session index: {0}' -f (Resolve-Path -LiteralPath $sessionIndex))
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }

  if ($exitCode -notin @(0,1)) {
    throw "CLI exited with unexpected code $exitCode"
  }
}
finally {
  try { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
