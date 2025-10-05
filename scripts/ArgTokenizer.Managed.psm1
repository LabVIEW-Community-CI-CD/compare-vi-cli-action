Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-CompareViShared {
  param(
    [string]$DllPath = (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'src/CompareVi.Shared/bin/Release/net8.0/CompareVi.Shared.dll')
  )
  try {
    if (-not (Test-Path -LiteralPath $DllPath)) { return $false }
    Add-Type -Path $DllPath -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-TokenizedArgsManaged {
  [CmdletBinding()] param([string]$InputString)
  if (-not (Import-CompareViShared)) { throw 'CompareVi.Shared not available' }
  [CompareVi.Shared.ArgTokenizer]::Tokenize($InputString)
}

function Normalize-FlagValuePairsManaged {
  [CmdletBinding()] param([string[]]$Tokens)
  if (-not (Import-CompareViShared)) { throw 'CompareVi.Shared not available' }
  [CompareVi.Shared.ArgTokenizer]::NormalizeFlagValuePairs($Tokens)
}

Export-ModuleMember -Function *

