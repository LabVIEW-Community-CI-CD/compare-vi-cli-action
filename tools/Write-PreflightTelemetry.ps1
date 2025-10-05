#Requires -Version 7.0
<#!
.SYNOPSIS
  Emit lightweight preflight telemetry JSON for the current runner.
.PARAMETER OutputPath
  Where to write the JSON (default: telemetry/preflight.json).
#>
[CmdletBinding()] param(
  [string] $OutputPath = 'telemetry/preflight.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Dir([string]$p){ $d = Split-Path -Parent $p; if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

$data = [ordered]@{
  schema      = 'preflight-telemetry/v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  os          = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
  arch        = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  psVersion   = $PSVersionTable.PSVersion.ToString()
  runner      = @{ name=$env:RUNNER_NAME; os=$env:RUNNER_OS; temp=$env:RUNNER_TEMP }
  git         = @{ sha=$env:GITHUB_SHA; ref=$env:GITHUB_REF; runId=$env:GITHUB_RUN_ID }
  toggles     = @{ INVOKER_REQUIRED=$env:INVOKER_REQUIRED; WATCH_CONSOLE=$env:WATCH_CONSOLE; LV_SUPPRESS_UI=$env:LV_SUPPRESS_UI }
}
New-Dir -p $OutputPath
$data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host ("preflight telemetry: {0}" -f (Resolve-Path $OutputPath).Path)

