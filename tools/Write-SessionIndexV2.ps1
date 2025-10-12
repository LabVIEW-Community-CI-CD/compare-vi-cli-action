#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$OutFileName = 'session-index.v2.json',
  [switch]$SkipBuild,
  [switch]$EmitEnv,
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

  $baseArgs = @(
    '--from-v1', $sessionIndexV1
  )

  if ($env:AGENT_TOGGLE_PROFILES) {
    $profiles = $env:AGENT_TOGGLE_PROFILES -split '[,;\s]' | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($profile in $profiles) {
      $baseArgs += @('--toggle-profile', $profile)
    }
  }

  if ($env:GITHUB_WORKFLOW) { $baseArgs += @('--workflow', $env:GITHUB_WORKFLOW) }
  if ($env:GITHUB_JOB) { $baseArgs += @('--job', $env:GITHUB_JOB) }
  if ($casesPath) {
    $casesArray = @($casesPath | Where-Object { $_ })
    if ($casesArray.Count -gt 0) {
      $lastEntry = $casesArray[$casesArray.Count - 1].ToString().Trim()
      if ($lastEntry.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
        $baseArgs += @('--cases', $lastEntry)
      }
    }
  }

  $cliArgsJson = @($baseArgs + @('--out', $outPath))

  & $NodePath $cliPath @cliArgsJson
  if ($LASTEXITCODE -ne 0) {
    throw "session-index CLI exited with code $LASTEXITCODE"
  }

  if ($EmitEnv) {
    if (-not $env:GITHUB_ENV) {
      Write-Warning 'EmitEnv was requested but GITHUB_ENV is not set.'
    } else {
      $cliArgsEnv = @($baseArgs + @('--format', 'env', '--no-check'))
      $envOutput = & $NodePath $cliPath @cliArgsEnv
      if ($LASTEXITCODE -ne 0) {
        throw "session-index CLI (env) exited with code $LASTEXITCODE"
      }
      $envOutput | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
  }

  $checkPath = Join-Path $repoRoot 'dist' 'src' 'session-index' 'check.js'
  if (Test-Path -LiteralPath $checkPath -PathType Leaf) {
    & $NodePath $checkPath --file $outPath --base $repoRoot
    if ($LASTEXITCODE -ne 0) {
      throw "session-index requirement check failed with exit code $LASTEXITCODE"
    }
  } else {
    Write-Warning "session-index check script not found at $checkPath"
  }

  Write-Host "session-index v2 written to $outPath"
  return $outPath
} finally {
  Pop-Location
}
