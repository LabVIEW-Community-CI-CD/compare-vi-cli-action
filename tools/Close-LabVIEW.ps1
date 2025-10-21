<#
.SYNOPSIS
  Gracefully closes a running LabVIEW instance using the provider-agnostic CLI abstraction.

.DESCRIPTION
  Routes the CloseLabVIEW operation through tools/LabVIEWCli.psm1, which selects an available provider
  (LabVIEWCLI.exe today, g-cli in the future) and normalises arguments. Optional parameters mirror
  historic behaviour and map onto canonical parameters.

.PARAMETER LabVIEWExePath
  Explicit LabVIEW executable path. When omitted, environment variables and canonical install
  locations are used to derive the path.

.PARAMETER MinimumSupportedLVVersion
  LabVIEW version to target when the executable path is derived automatically.

.PARAMETER SupportedBitness
  LabVIEW bitness (32 or 64) used when deriving the executable path.

.PARAMETER LabVIEWCliPath
  Optional override of the LabVIEWCLI.exe path (sets LABVIEWCLI_PATH for the duration of the call).

.PARAMETER Provider
  Explicit provider name to use (defaults to 'auto').

.PARAMETER Preview
  When set, shows the resolved provider and command without executing it.
#>
[CmdletBinding()]
param(
  [string]$LabVIEWExePath,
  [string]$MinimumSupportedLVVersion,
  [ValidateSet('32','64')]
  [string]$SupportedBitness,
  [string]$LabVIEWCliPath,
  [string]$Provider = 'auto',
  [switch]$Preview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LabVIEWCli.psm1') -Force

$params = @{}
if ($PSBoundParameters.ContainsKey('LabVIEWExePath')) { $params.labviewPath = $LabVIEWExePath }
if ($PSBoundParameters.ContainsKey('MinimumSupportedLVVersion')) { $params.labviewVersion = $MinimumSupportedLVVersion }
if ($PSBoundParameters.ContainsKey('SupportedBitness')) { $params.labviewBitness = $SupportedBitness }

$previousCliPath = $null
$cliPathOverride = $false
if ($PSBoundParameters.ContainsKey('LabVIEWCliPath') -and $LabVIEWCliPath) {
  $previousCliPath = [System.Environment]::GetEnvironmentVariable('LABVIEWCLI_PATH')
  [System.Environment]::SetEnvironmentVariable('LABVIEWCLI_PATH', $LabVIEWCliPath)
  $cliPathOverride = $true
}

try {
  $result = Invoke-LVOperation -Operation 'CloseLabVIEW' -Params $params -Provider $Provider -Preview:$Preview
  if ($Preview) {
    return $result
  }
  Write-Host ("[Close-LabVIEW] Provider: {0}" -f $result.provider) -ForegroundColor DarkGray
  Write-Host ("[Close-LabVIEW] Command : {0}" -f $result.command) -ForegroundColor DarkGray
  if ($result.exitCode -ne 0) {
    $stderr = $result.PSObject.Properties['stderr'] ? $result.stderr : ''
    if ($stderr -match '-350000' -or $stderr -match 'failed to establish a connection with LabVIEW') {
      Write-Host "[Close-LabVIEW] LabVIEWCLI reported no running LabVIEW instance; treating as already closed." -ForegroundColor DarkGray
      return
    }
    throw "Provider '$($result.provider)' exited with code $($result.exitCode)."
  }
  Write-Host "[Close-LabVIEW] LabVIEW shutdown command completed successfully." -ForegroundColor DarkGreen
} catch {
  $message = $_.Exception.Message
  if ($message -match 'executable not found' -or $message -match 'No registered provider') {
    Write-Warning $message
    return
  }
  Write-Error ("Close-LabVIEW.ps1 failed: {0}" -f $message)
  exit 1
} finally {
  if ($cliPathOverride) {
    [System.Environment]::SetEnvironmentVariable('LABVIEWCLI_PATH', $previousCliPath)
  }
}
