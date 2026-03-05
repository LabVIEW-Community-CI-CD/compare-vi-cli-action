#Requires -Version 7.0

param(
  [string]$RequestsPath,
  [string]$CapturesRoot,
  [string]$SummaryPath,
  [switch]$DryRun,
  [int]$TimeoutSeconds = 600,
  [string]$CompareScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

function Ensure-Directory {
  param([string]$Path)
  $item = New-Item -ItemType Directory -Force -Path $Path
  return (Resolve-Path -LiteralPath $item).Path
}

function Convert-ToRelativePath {
  param(
    [string]$Path,
    [string]$Base
  )
  if (-not $Path) { return $null }
  try {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $full = $resolved.Path
    if ([string]::IsNullOrWhiteSpace($Base)) { return $full }
    if ([System.IO.Path]::IsPathRooted($Base) -and (Test-Path -LiteralPath $Base -PathType Container)) {
      $rel = [System.IO.Path]::GetRelativePath($Base, $full)
      if ($rel -and -not $rel.StartsWith('..')) { return $rel }
    }
    return $full
  } catch { return $Path }
}

function Sanitize-Name {
  param([string]$Input, [int]$Index)
  if (-not $Input) { return ('vi-{0:D3}' -f $Index) }
  $safe = $Input -replace '[^A-Za-z0-9_.-]+', '_'
  $safe = $safe.Trim('_')
  if (-not $safe) { $safe = 'vi' }
  return ('{0:D3}-{1}' -f $Index, $safe)
}

$repoRoot = Resolve-RepoRoot
if (-not $RequestsPath) {
  $RequestsPath = Join-Path $repoRoot 'tests/results/_agent/icon-editor/vi-diff/vi-diff-requests.json'
}

if (-not (Test-Path -LiteralPath $RequestsPath -PathType Leaf)) {
  Write-Host "No VI diff requests found at $RequestsPath; nothing to do." -ForegroundColor Yellow
  return
}

$requests = Get-Content -LiteralPath $RequestsPath -Raw | ConvertFrom-Json -Depth 6
if (-not $requests) {
  Write-Host "VI diff requests file was empty; nothing to do." -ForegroundColor Yellow
  return
}

$requestItems = @()
if ($requests.PSObject.Properties['requests']) {
  $requestItems = @($requests.requests)
} elseif ($requests.PSObject.Properties['count']) {
  $requestItems = @($requests)
} else {
  throw "Unrecognised vi-diff requests schema in $RequestsPath."
}

if ($requestItems.Count -eq 0) {
  Write-Host "VI diff request list is empty; nothing to compare." -ForegroundColor Yellow
  return
}

if (-not $CapturesRoot) {
  $CapturesRoot = Join-Path $repoRoot 'tests/results/_agent/icon-editor/vi-diff-captures'
}
$capturesRootResolved = Ensure-Directory $CapturesRoot

$summaryEntries = @()
$counts = [ordered]@{
  total     = $requestItems.Count
  compared  = 0
  same      = 0
  different = 0
  skipped   = 0
  dryRun    = 0
  errors    = 0
}

$compareScript = if ($CompareScript) { $CompareScript } else { Join-Path $repoRoot 'tools' 'Run-HeadlessCompare.ps1' }
if (-not $DryRun) {
  if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
    throw "Run-HeadlessCompare.ps1 not found at $compareScript"
  }
  $compareScript = (Resolve-Path -LiteralPath $compareScript).Path
} elseif ($CompareScript -and (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  $compareScript = (Resolve-Path -LiteralPath $compareScript).Path
}

for ($i = 0; $i -lt $requestItems.Count; $i++) {
  $req = $requestItems[$i]
  $safeName = Sanitize-Name -Input $req.relPath -Index ($i + 1)
  $pairRoot = Join-Path $capturesRootResolved $safeName
  if (Test-Path -LiteralPath $pairRoot) {
    try { Remove-Item -LiteralPath $pairRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
  [void](Ensure-Directory $pairRoot)

  $basePath = $req.base
  $headPath = $req.head
  $captureRelative = Convert-ToRelativePath -Path $pairRoot -Base $capturesRootResolved

  $status = 'pending'
  $message = $null
  $outcomeNode = $null
  $artifacts = [ordered]@{}

  $baseExists = $basePath -and (Test-Path -LiteralPath $basePath -PathType Leaf)
  $headExists = $headPath -and (Test-Path -LiteralPath $headPath -PathType Leaf)

  if (-not $headExists) {
    $status = 'error'
    $message = 'Head VI path missing.'
    $counts.errors++
  } elseif (-not $baseExists) {
    $status = 'skipped'
    $message = 'Baseline VI unavailable; head-only comparison skipped.'
    $counts.skipped++
  } elseif ($DryRun.IsPresent) {
    $status = 'dry-run'
    $message = 'Dry run requested; compare not executed.'
    $counts.dryRun++
    $counts.skipped++
  } else {
    $compareParams = @{
      BaseVi        = $basePath
      HeadVi        = $headPath
      OutputRoot    = $pairRoot
      WarmupMode    = 'skip'
      UseRawPaths   = $true
      TimeoutSeconds = $TimeoutSeconds
      RenderReport  = $true
    }

    $compareExit = 0
    $compareError = $null
    try {
      & $compareScript @compareParams | Out-Null
      $compareExit = $LASTEXITCODE
    } catch {
      $compareExit = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
      $compareError = $_.Exception.Message
    }

    $sessionPath = Join-Path $pairRoot 'session-index.json'
    $captureJsonPath = Join-Path $pairRoot 'compare/lvcompare-capture.json'
    $compareEvents = Join-Path $pairRoot 'compare/compare-events.ndjson'
    $reportPath = Join-Path $pairRoot 'compare/compare-report.html'

    $artifacts.sessionIndex = Convert-ToRelativePath -Path $(if (Test-Path -LiteralPath $sessionPath) { $sessionPath } else { $null }) -Base $repoRoot
    $artifacts.captureJson  = Convert-ToRelativePath -Path $(if (Test-Path -LiteralPath $captureJsonPath) { $captureJsonPath } else { $null }) -Base $repoRoot
    $artifacts.compareEvents = Convert-ToRelativePath -Path $(if (Test-Path -LiteralPath $compareEvents) { $compareEvents } else { $null }) -Base $repoRoot
    $artifacts.compareReport = Convert-ToRelativePath -Path $(if (Test-Path -LiteralPath $reportPath) { $reportPath } else { $null }) -Base $repoRoot

    if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
      $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json -Depth 6
      if ($session -and $session.PSObject.Properties['outcome']) {
        $outcomeNode = [ordered]@{}
        if ($session.outcome.PSObject.Properties['exitCode']) { $outcomeNode.exitCode = [int]$session.outcome.exitCode }
        if ($session.outcome.PSObject.Properties['seconds']) { $outcomeNode.seconds = [double]$session.outcome.seconds }
        if ($session.outcome.PSObject.Properties['diff']) { $outcomeNode.diff = [bool]$session.outcome.diff }
      }
      if ($session.PSObject.Properties['error'] -and $session.error) {
        $message = $session.error
      }
    }

    if (-not $outcomeNode) { $outcomeNode = [ordered]@{} }
    if (-not $outcomeNode.PSObject.Properties['exitCode']) { $outcomeNode.exitCode = $compareExit }

    if ($compareError) {
      $status = 'error'
      $message = if ($message) { "$message | $compareError" } else { $compareError }
      $counts.errors++
    } elseif ($outcomeNode -and $outcomeNode.diff -eq $true) {
      $status = 'different'
      $counts.different++
      $counts.compared++
    } elseif ($outcomeNode -and $outcomeNode.diff -eq $false -and ($outcomeNode.exitCode -eq 0)) {
      $status = 'same'
      $counts.same++
      $counts.compared++
    } elseif ($compareExit -eq 0 -and -not $outcomeNode.diff) {
      $status = 'same'
      $outcomeNode.diff = $false
      $counts.same++
      $counts.compared++
    } elseif ($compareExit -eq 1 -and -not $outcomeNode.diff) {
      $status = 'different'
      $outcomeNode.diff = $true
      $counts.different++
      $counts.compared++
    } else {
      $status = 'error'
      if (-not $message) { $message = 'Comparison outcome could not be determined.' }
      $counts.errors++
    }
  }

  $entryBase = Convert-ToRelativePath -Path $req.base -Base $repoRoot
  $entryHead = Convert-ToRelativePath -Path $req.head -Base $repoRoot

  $entry = [ordered]@{
    name       = $req.name
    relPath    = $req.relPath
    base       = $entryBase
    head       = $entryHead
    status     = $status
    message    = $message
    captureDir = $captureRelative
    artifacts  = $artifacts
    outcome    = $outcomeNode
  }
  $summaryEntries += $entry
}

if (-not $SummaryPath) {
  $SummaryPath = Join-Path $capturesRootResolved 'vi-comparison-summary.json'
}

$summary = [ordered]@{
  schema = 'icon-editor/vi-comparison-summary@v1'
  generatedAt = (Get-Date).ToString('o')
  counts = $counts
  requests = $summaryEntries
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding utf8

if ($counts.errors -gt 0) {
  throw "VI comparison encountered $($counts.errors) error(s)."
}

return $summary
