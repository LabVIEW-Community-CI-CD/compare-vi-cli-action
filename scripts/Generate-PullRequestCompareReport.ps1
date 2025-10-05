<#
.SYNOPSIS
 Generates HTML + Markdown diff summary (PR body snippet) for repository VI1.vi vs VI2.vi using LVCompare.
.DESCRIPTION
 Runs one real LVCompare invocation (canonical path enforced) against VI1.vi & VI2.vi in repo root.
 Emits:
  - HTML report file (self-contained) via Render-CompareReport.ps1
  - Markdown snippet file with key metadata + link placeholder
  - JSON summary file (command, exitCode, diff, timing)
.PARAMETER OutputDirectory
 Target directory for artifacts (created if missing). Default: ./compare-artifacts
#>
[CmdletBinding()] param(
  [string]$OutputDirectory = 'compare-artifacts',
  [switch]$LoopMode,
  [int]$LoopIterations = 15,
  [double]$LoopIntervalSeconds = 0,
  [ValidateSet('Exact','StreamingReservoir','Hybrid')] [string]$QuantileStrategy = 'StreamingReservoir',
  [int]$StreamCapacity = 300,
  [int]$HistogramBins = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) { throw "LVCompare not found at canonical path: $canonical" }
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$baseVi = (Resolve-Path (Join-Path $repoRoot 'VI1.vi')).Path
$headVi = (Resolve-Path (Join-Path $repoRoot 'VI2.vi')).Path
foreach ($p in @($baseVi,$headVi)) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Required VI file missing: $p" }
  $len = (Get-Item -LiteralPath $p).Length
  if ($len -lt 1024) { Write-Warning "VI file $p is unusually small ($len bytes) – ensure this is a real LabVIEW .vi binary." }
}
Import-Module (Join-Path $repoRoot 'scripts' 'CompareVI.psm1') -Force

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

if ($LoopMode) {
  # Import loop module
  Import-Module (Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
  Write-Host "Invoking Loop Mode (Iterations=$LoopIterations Strategy=$QuantileStrategy) on:`n Base=$baseVi`n Head=$headVi" -ForegroundColor Cyan
  $exec = {
    param($cli,$base,$head,$extraArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName=$cli; ArgumentList=@($base,$head) }
    $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true; $psi.UseShellExecute=$false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return $p.ExitCode
  }
  $loop = Invoke-IntegrationCompareLoop -Base $baseVi -Head $headVi -MaxIterations $LoopIterations -IntervalSeconds $LoopIntervalSeconds -CompareExecutor $exec -QuantileStrategy $QuantileStrategy -StreamCapacity $StreamCapacity -HistogramBins $HistogramBins -Quiet -PassThroughPaths -BypassCliValidation -SkipValidation
  # Derive pseudo single-run result semantics
  $res = [pscustomobject]@{
    ExitCode = 0
    Diff = ($loop.DiffCount -gt 0)
    Command = "(loop-mode) LVCompare $([System.IO.Path]::GetFileName($baseVi)) $([System.IO.Path]::GetFileName($headVi))"
    CliPath = $canonical
    CompareDurationSeconds = $loop.AverageSeconds
  }
} else {
  Write-Host "Invoking LVCompare on:`n Base=$baseVi`n Head=$headVi" -ForegroundColor Cyan
  $res = Invoke-CompareVI -Base $baseVi -Head $headVi -LvComparePath $canonical -FailOnDiff:$false
}

$htmlPath = Join-Path $OutputDirectory 'compare-report.html'
$renderer = Join-Path $repoRoot 'scripts' 'Render-CompareReport.ps1'
& $renderer -Command $res.Command -ExitCode $res.ExitCode -Diff ($res.Diff.ToString().ToLower()) -CliPath $res.CliPath -OutputPath $htmlPath -DurationSeconds $res.CompareDurationSeconds

$summary = [ordered]@{
  base = $baseVi
  head = $headVi
  mode = if ($LoopMode) { 'loop' } else { 'single' }
  exitCode = $res.ExitCode
  diff = $res.Diff
  command = $res.Command
  compareDurationSeconds = $res.CompareDurationSeconds
  generatedUtc = [DateTime]::UtcNow.ToString('o')
}
if ($LoopMode) {
  $summary.loop = [ordered]@{
    iterations = $loop.Iterations
    diffCount = $loop.DiffCount
    errorCount = $loop.ErrorCount
    averageSeconds = $loop.AverageSeconds
    totalSeconds = $loop.TotalSeconds
    quantileStrategy = $loop.QuantileStrategy
    streamingWindowCount = $loop.StreamingWindowCount
    percentiles = $loop.Percentiles
    histogram = $loop.Histogram
  }
}
$summaryPath = Join-Path $OutputDirectory 'compare-summary.json'
$summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $summaryPath -Encoding utf8

$mdPath = Join-Path $OutputDirectory 'pr-diff-snippet.md'
$diffStatus = if ($res.Diff) { '⚠️ Differences detected' } else { '✅ No differences' }
$md = @()
$md += '### LabVIEW VI Compare'
$md += "Status: $diffStatus (exit code $($res.ExitCode))"
$md += ''
$md += '| Metric | Value |'
$md += '|--------|-------|'
$md += "| Mode | $(if ($LoopMode) { 'Loop' } else { 'Single' }) |"
$md += "| Base | $([System.IO.Path]::GetFileName($baseVi)) |"
$md += "| Head | $([System.IO.Path]::GetFileName($headVi)) |"
$md += "| Diff | $($res.Diff) |"
$md += "| Duration (s) | $([string]::Format('{0:F3}',$res.CompareDurationSeconds)) |"
if ($LoopMode -and $loop.Percentiles) {
  $md += "| Iterations | $($loop.Iterations) |"
  $md += "| Avg (s) | $([string]::Format('{0:F4}',$loop.AverageSeconds)) |"
  $md += "| p50/p90/p99 (s) | $([string]::Format('{0:F4}',$loop.Percentiles.p50))/$([string]::Format('{0:F4}',$loop.Percentiles.p90))/$([string]::Format('{0:F4}',$loop.Percentiles.p99)) |"
  if ($loop.StreamingWindowCount -gt 0) { $md += "| Streaming Window | $($loop.StreamingWindowCount) |" }
  if ($loop.Histogram) { $md += "| Histogram Bins | $($loop.Histogram.Count) |" }
}
$md += ''
$md += '_Attach `compare-report.html` as an artifact or render inline if your review tooling supports raw HTML._'
$md -join "`n" | Out-File -FilePath $mdPath -Encoding utf8

Write-Host "Artifacts generated:" -ForegroundColor Green
Write-Host " HTML : $htmlPath"
Write-Host " JSON : $summaryPath"
Write-Host " PR MD: $mdPath"

# Emit simple console summary for CI logs
Write-Host "--- Compare Summary ---" -ForegroundColor Magenta
Write-Host (Get-Content -LiteralPath $mdPath -Raw)

return [pscustomobject]@{ Html=$htmlPath; Summary=$summaryPath; Markdown=$mdPath; Diff=$res.Diff; Mode= (if ($LoopMode){'loop'}else{'single'}) }
