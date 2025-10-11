#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$OutFileName = 'session-index.v2.json',
  [switch]$SkipBuild,
  [string]$NodePath = 'node'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sessionIndexV1 = Join-Path $ResultsDir 'session-index.json'
if (-not (Test-Path -LiteralPath $sessionIndexV1 -PathType Leaf)) {
  throw "session-index.json not found at $sessionIndexV1"
}

$outPath = if ([System.IO.Path]::IsPathRooted($OutFileName)) {
  $OutFileName
} else {
  Join-Path $ResultsDir $OutFileName
}

Push-Location $repoRoot
try {
  $nodeModulesPath = Join-Path $repoRoot 'node_modules'
  if (-not (Test-Path -LiteralPath $nodeModulesPath -PathType Container)) {
    Write-Host 'Installing Node dependencies for session-index v2...'
    npm ci --silent | Write-Host
  }

  if (-not $SkipBuild) {
    Write-Host 'Running TypeScript build for session-index v2...'
    npm run build --silent | Write-Host
  }

  $cliPath = Join-Path $repoRoot 'dist' 'src' 'session-index' 'cli.js'
  if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    throw "CLI not found at $cliPath. Ensure the TypeScript build succeeded."
  }

  $casesPath = $null
  try {
    $casesPath = pwsh -File (Join-Path $repoRoot 'tools' 'Write-SessionIndexV2Cases.ps1') -ResultsDir $ResultsDir
  } catch {
    Write-Warning "Failed to write session-index v2 cases: $_"
  }

  $cliArgs = @(
    '--from-v1', $sessionIndexV1,
    '--out', $outPath
  )
  if ($env:GITHUB_WORKFLOW) { $cliArgs += @('--workflow', $env:GITHUB_WORKFLOW) }
  if ($env:GITHUB_JOB) { $cliArgs += @('--job', $env:GITHUB_JOB) }
  if ($casesPath) { $cliArgs += @('--cases', $casesPath) }

  & $NodePath $cliPath @cliArgs
  if ($LASTEXITCODE -ne 0) {
    throw "session-index CLI exited with code $LASTEXITCODE"
  }

  Write-Host "session-index v2 written to $outPath"
  return $outPath
} finally {
  Pop-Location
}
