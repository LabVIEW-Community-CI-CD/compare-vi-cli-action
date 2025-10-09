param(
  [string]$TestsPath = 'tests',
  [string]$ResultsRoot = 'tests/results',
  [string[]]$IncludePatterns,
  [switch]$IncludeIntegration,
  [ValidateSet('soft','strict')][string]$Isolation = 'soft',
  [int]$MaxFileSeconds = 0,
  [switch]$EmitIts,
  [switch]$DryRun,
  [switch]$TraceMatrix,
  [switch]$RenderTraceMatrixHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePathCandidates = @(
  (Join-Path $PSScriptRoot 'Pester-Invoker.psm1'),
  (Join-Path (Join-Path $PSScriptRoot '..') 'scripts/Pester-Invoker.psm1')
)
$modulePath = $modulePathCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $modulePath) {
  Write-Error "Unable to locate Pester-Invoker.psm1"
  exit 1
}

Import-Module $modulePath -Force

$traceMatrixEnv = $env:TRACE_MATRIX
if (-not $TraceMatrix -and $traceMatrixEnv -match '^(?i:1|true|yes|on)$') { $TraceMatrix = $true }
$traceMatrixHtmlEnv = $env:TRACE_MATRIX_HTML
if (-not $RenderTraceMatrixHtml -and $traceMatrixHtmlEnv -match '^(?i:1|true|yes|on)$') { $RenderTraceMatrixHtml = $true }
if ($RenderTraceMatrixHtml) { $TraceMatrix = $true } # HTML implies JSON

function Get-TaggedFiles {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string[]]$Patterns,
    [ValidateSet('Unit','Integration')][string]$Tag
  )
  $files = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue | Sort-Object FullName)
  if ($Patterns -and $Patterns.Count -gt 0) {
    $matches = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($file in $files) {
      $name = $file.Name
      $matched = $false
      foreach ($pattern in $Patterns) {
        if ($name -like $pattern) { $matched = $true; break }
      }
      if ($matched) { $matches.Add($file) | Out-Null }
    }
    $files = $matches.ToArray()
  }
  $regex = "-Tag\s*'?$Tag'?"
  $tagMatches = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  foreach ($file in $files) {
    try {
      $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    } catch { continue }
    if ($content -match $regex) { $tagMatches.Add($file) | Out-Null }
  }
  $tagMatches.ToArray()
}

Write-Host "[SingleLoop] TestsPath=$TestsPath ResultsRoot=$ResultsRoot Isolation=$Isolation" -ForegroundColor Cyan
if ($IncludePatterns) { Write-Host ("[SingleLoop] IncludePatterns: {0}" -f ($IncludePatterns -join ', ')) -ForegroundColor Cyan }
if ($TraceMatrix) {
  Write-Host "[SingleLoop] Traceability matrix generation is enabled." -ForegroundColor DarkCyan
  if ($RenderTraceMatrixHtml) { Write-Host "[SingleLoop] HTML traceability report requested." -ForegroundColor DarkCyan }
}

$unitFiles = @((Get-TaggedFiles -Root $TestsPath -Patterns $IncludePatterns -Tag 'Unit'))
$integrationFiles = @((Get-TaggedFiles -Root $TestsPath -Patterns $IncludePatterns -Tag 'Integration'))

$unitCount = ($unitFiles | Measure-Object).Count
$integrationCount = ($integrationFiles | Measure-Object).Count

Write-Host ("[SingleLoop] Unit files: {0}" -f $unitCount)
Write-Host ("[SingleLoop] Integration files: {0}" -f $integrationCount)

if ($DryRun) {
  Write-Host '[SingleLoop] Dry run listing:' -ForegroundColor Yellow
  foreach ($f in $unitFiles) { Write-Host ("  [Unit] {0}" -f $f.FullName) }
  if ($IncludeIntegration) {
    foreach ($f in $integrationFiles) { Write-Host ("  [Integ] {0}" -f $f.FullName) }
  }
  exit 0
}

$session = New-PesterInvokerSession -ResultsRoot $ResultsRoot -Isolation $Isolation
$failedFiles = New-Object System.Collections.Generic.List[string]
$slow = New-Object System.Collections.Generic.List[psobject]

function Invoke-Category {
  param([System.IO.FileInfo[]]$Files,[string]$Category)
  $failCount = 0
  foreach ($file in $Files) {
    $res = Invoke-PesterFile -Session $session -File $file.FullName -Category $Category -EmitIts:$EmitIts -MaxSeconds $MaxFileSeconds
    $slow.Add($res)
    if ($res.TimedOut) {
      Write-Warning ("[SingleLoop] Timeout ({0}s): {1}" -f $MaxFileSeconds, $file.FullName)
      $failedFiles.Add($file.FullName) | Out-Null
      $failCount++
    } elseif ($res.Counts.failed -gt 0 -or $res.Counts.errors -gt 0) {
      $failedFiles.Add($file.FullName) | Out-Null
      $failCount++
    }
  }
  $failCount
}

$unitFailures = Invoke-Category -Files $unitFiles -Category 'Unit'
$integrationFailures = 0
if ($IncludeIntegration -and $unitFailures -eq 0) {
  $integrationFailures = Invoke-Category -Files $integrationFiles -Category 'Integration'
} elseif ($IncludeIntegration -and $unitFailures -gt 0) {
  Write-Warning '[SingleLoop] Skipping Integration files due to Unit failures.'
}

$topSlow = @($slow | Sort-Object DurationMs -Descending | Select-Object -First 5)
Complete-PesterInvokerSession -Session $session -FailedFiles $failedFiles -TopSlow $topSlow | Out-Null

if ($TraceMatrix) {
  $builderCandidates = @(
    (Join-Path (Join-Path $PSScriptRoot '..') 'tools/Traceability-Matrix.ps1'),
    (Join-Path $PSScriptRoot 'Traceability-Matrix.ps1')
  )
  $builderPath = $builderCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($builderPath) {
    $invokeArgs = @{
      TestsPath   = $TestsPath
      ResultsRoot = $ResultsRoot
      RunId       = $session.RunId
      Seed        = $session.Seed
    }
    if ($IncludePatterns) { $invokeArgs.IncludePatterns = $IncludePatterns }
    if ($RenderTraceMatrixHtml) { $invokeArgs.RenderHtml = $true }
    Write-Host "[SingleLoop] Invoking traceability matrix builder..." -ForegroundColor DarkCyan
    pwsh -NoLogo -NoProfile -File $builderPath @invokeArgs
  } else {
    Write-Warning "[SingleLoop] Trace matrix requested but tools/Traceability-Matrix.ps1 was not found."
  }
}

Write-Host "[SingleLoop] Unit failures: $unitFailures"
if ($IncludeIntegration) { Write-Host "[SingleLoop] Integration failures: $integrationFailures" }
if ($topSlow.Count -gt 0) {
  Write-Host '[SingleLoop] Slowest files:'
  foreach ($entry in $topSlow) {
    Write-Host ("  {0} — {1} ms" -f $entry.File, $entry.DurationMs)
  }
}

if ($failedFiles.Count -gt 0) {
  Write-Host '[SingleLoop] Failed files:' -ForegroundColor Red
  foreach ($file in $failedFiles) { Write-Host "  $file" -ForegroundColor Red }
  exit 1
}

Write-Host '[SingleLoop] All requested tests passed.' -ForegroundColor Green
exit 0
