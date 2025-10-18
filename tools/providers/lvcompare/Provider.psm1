Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $toolsRoot 'VendorTools.psm1') -Force

$script:providerId = 'lvcompare'

function Get-RequiredParameterValue {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [Parameter()][hashtable]$Params,
    [Parameter(Mandatory)][string]$Key
  )

  if (-not $Params) {
    throw "Operation '$Operation' requires parameter '$Key'."
  }
  if (-not $Params.ContainsKey($Key)) {
    throw "Operation '$Operation' requires parameter '$Key'."
  }
  $value = $Params[$Key]
  if ($null -eq $value) {
    throw "Operation '$Operation' requires parameter '$Key'."
  }
  if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
    throw "Operation '$Operation' requires parameter '$Key'."
  }
  return [string]$value
}

function Resolve-LVCompareBinaryPath {
  param([hashtable]$Params)

  if ($Params -and $Params.ContainsKey('lvcomparePath') -and $Params.lvcomparePath) {
    return [string]$Params.lvcomparePath
  }

  $path = Resolve-LVComparePath
  if ($path) { return $path }

  throw 'Unable to resolve LVCompare.exe. Install at the canonical location or provide -lvcomparePath.'
}

function New-LVCompareInvocationPlan {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [Parameter()][hashtable]$Params
  )

  if ($Operation -ne 'CreateComparisonReport') {
    throw "Operation '$Operation' is not supported by the lvcompare provider."
  }

  $binaryPath = Resolve-LVCompareBinaryPath -Params $Params
  $vi1 = Get-RequiredParameterValue -Operation $Operation -Params $Params -Key 'vi1'
  $vi2 = Get-RequiredParameterValue -Operation $Operation -Params $Params -Key 'vi2'

  $arguments = @($vi1, $vi2)
  if ($Params -and $Params.ContainsKey('flags') -and $Params.flags) {
    foreach ($flag in $Params.flags) {
      if ($null -ne $flag -and $flag -ne '') {
        $arguments += [string]$flag
      }
    }
  }

  return [pscustomobject]@{
    BinaryPath = $binaryPath
    Arguments  = $arguments
  }
}

function New-CompareVIProvider {
  $supportedOperations = @('CreateComparisonReport')
  $provider = [pscustomobject]@{
    Id                  = $script:providerId
    SupportedOperations = $supportedOperations
  }

  $null = $provider | Add-Member -MemberType ScriptMethod -Name SupportsOperation -Value {
    param($Operation)
    return $this.SupportedOperations -contains $Operation
  }

  $null = $provider | Add-Member -MemberType ScriptMethod -Name ResolveBinaryPath -Value {
    param($Params)
    return Resolve-LVCompareBinaryPath -Params $Params
  }

  $null = $provider | Add-Member -MemberType ScriptMethod -Name GetInvocationPlan -Value {
    param($Operation,$Params)
    return New-LVCompareInvocationPlan -Operation $Operation -Params $Params
  }

  return $provider
}

Export-ModuleMember -Function New-CompareVIProvider
