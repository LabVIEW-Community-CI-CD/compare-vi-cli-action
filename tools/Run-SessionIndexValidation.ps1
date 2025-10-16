[CmdletBinding()]
param(
  [string]$ResultsPath = 'tests/results/_validate-sessionindex',
  [string]$SchemaPath = 'docs/schemas/session-index-v1.schema.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Get-Location).Path
$discoveryScript = Join-Path $workspace 'dist/tools/test-discovery.js'

if (-not (Test-Path -LiteralPath $discoveryScript)) {
  Write-Host '::notice::TypeScript build artifacts missing; running npm run build...'
  $wrapperDir = Join-Path $workspace 'tools/npm/bin'
  $npmWrapper = if ($IsWindows) { Join-Path $wrapperDir 'npm.cmd' } else { Join-Path $wrapperDir 'npm' }
  try {
    & $npmWrapper run build | Out-Host
  } catch {
    Write-Error "npm run build failed: $_"
    exit 2
  }
  if (-not (Test-Path -LiteralPath $discoveryScript)) {
    Write-Error "test-discovery.js not found at $discoveryScript after npm run build"
    exit 2
  }
}

if (-not (Test-Path -LiteralPath $ResultsPath)) {
  New-Item -ItemType Directory -Force -Path $ResultsPath | Out-Null
}

pwsh -NoLogo -NoProfile -File ./tools/Quick-DispatcherSmoke.ps1 -ResultsPath $ResultsPath -PreferWorkspace | Out-Host

$sessionIndex = Join-Path $ResultsPath 'session-index.json'
if (-not (Test-Path -LiteralPath $sessionIndex)) {
  Write-Error "session-index.json not found at $sessionIndex"
  exit 2
}

pwsh -NoLogo -NoProfile -File ./tools/Invoke-JsonSchemaLite.ps1 -JsonPath $sessionIndex -SchemaPath $SchemaPath | Out-Host
