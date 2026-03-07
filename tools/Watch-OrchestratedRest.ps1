<#
.SYNOPSIS
  Wrapper for the REST watcher that writes watcher-rest.json and merges it into session-index.json.

.DESCRIPTION
  Invokes the compiled Node watcher (dist/tools/watchers/orchestrated-watch.js) with robust defaults
  for grace windows, writes the summary to tests/results/_agent/watcher-rest.json, and then runs
  tools/Update-SessionIndexWatcher.ps1 to expose the summary under watchers.rest.

.PARAMETER RunId
  Workflow run id to follow. If omitted, provide -Branch to select the most recent run for that branch.

.PARAMETER Branch
  Branch name for latest-run selection when RunId is not provided.

.PARAMETER Workflow
  Workflow file to filter runs by when using -Branch (default: .github/workflows/ci-orchestrated.yml).

.PARAMETER PollMs
  Polling interval in milliseconds (default: 15000).

.PARAMETER ErrorGraceMs
  Consecutive-error grace window before aborting (default: 120000).

.PARAMETER NotFoundGraceMs
  Grace window for repeated 404 Not Found responses before aborting (default: 90000).

.PARAMETER OutPath
  Output JSON path for the watcher summary (default: tests/results/_agent/watcher-rest.json).
#>
[CmdletBinding()]
param(
  [int]$RunId,
  [string]$Branch,
  [string]$Workflow = '.github/workflows/ci-orchestrated.yml',
  [int]$PollMs = 15000,
  [int]$ErrorGraceMs = 120000,
  [int]$NotFoundGraceMs = 90000,
  [string]$OutPath = 'tests/results/_agent/watcher-rest.json',
  [string]$EventsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-WatchRestLog {
  param(
    [ValidateSet('info','warn','error')]
    [string]$Level = 'info',
    [Parameter(Mandatory = $true)]
    [string]$Message,
    [ConsoleColor]$ForegroundColor = 'Gray'
  )

  Write-Host ("[{0}] [watch-rest] {1}" -f $Level.ToLowerInvariant(), $Message) -ForegroundColor $ForegroundColor
}

function Resolve-RepoRoot { param([string]$Path) if ($Path) { return $Path } $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path; return $root }
$repoRoot = Resolve-RepoRoot
Push-Location $repoRoot
try {
  $outAbs = if ([System.IO.Path]::IsPathRooted($OutPath)) { $OutPath } else { Join-Path $repoRoot $OutPath }
  $outDir = Split-Path -Parent $outAbs
  if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
  $eventsAbs = if ($EventsPath) {
    if ([System.IO.Path]::IsPathRooted($EventsPath)) { $EventsPath } else { Join-Path $repoRoot $EventsPath }
  } else {
    Join-Path $outDir 'watcher-events.ndjson'
  }

  $watcherJs = Join-Path $repoRoot 'dist/tools/watchers/orchestrated-watch.js'
  if (-not (Test-Path -LiteralPath $watcherJs -PathType Leaf)) {
    Write-WatchRestLog -Level info -Message 'Compiling TypeScript watcher (tsc -p tsconfig.cli.json)...' -ForegroundColor DarkGray
    & npx tsc -p tsconfig.cli.json | Out-Null
  }
  if (-not (Test-Path -LiteralPath $watcherJs -PathType Leaf)) {
    throw 'Watcher binary not found after compile: dist/tools/watchers/orchestrated-watch.js'
  }

  $args = @(
    '--poll-ms', [string]$PollMs,
    '--error-grace-ms', [string]$ErrorGraceMs,
    '--notfound-grace-ms', [string]$NotFoundGraceMs,
    '--out', $outAbs,
    '--events-out', $eventsAbs
  )
  if ($RunId -gt 0) {
    $args = @('--run-id', [string]$RunId) + $args
  } elseif ($Branch) {
    $args = @('--branch', $Branch, '--workflow', $Workflow) + $args
  } else {
    throw 'Provide -RunId or -Branch'
  }

  Write-WatchRestLog -Level info -Message ("node {0} {1}" -f (Resolve-Path $watcherJs).Path, ($args -join ' ')) -ForegroundColor DarkGray
  & node $watcherJs @args
  $exit = $LASTEXITCODE

  Write-WatchRestLog -Level info -Message 'Merging watcher summary into session-index.json' -ForegroundColor DarkGray
  & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools/Update-SessionIndexWatcher.ps1') -ResultsDir (Join-Path $repoRoot 'tests/results') -WatcherJson $outAbs -WatcherEvents $eventsAbs

  exit $exit
} finally { Pop-Location }
