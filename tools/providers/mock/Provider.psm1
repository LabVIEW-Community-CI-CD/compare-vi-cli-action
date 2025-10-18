Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:providerId = 'mock'

function Resolve-MockBinaryPath {
  $override = $env:MOCK_PROVIDER_BINARY
  if ($override) {
    try {
      if (Test-Path -LiteralPath $override -PathType Leaf) {
        return (Resolve-Path -LiteralPath $override -ErrorAction Stop).Path
      }
    } catch {}
    return $override
  }

  try {
    $pwsh = Get-Command -Name 'pwsh' -ErrorAction Stop
    if ($pwsh) { return $pwsh.Source }
  } catch {}

  return 'pwsh'
}

function New-MockInvocationPlan {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [hashtable]$Params
  )
  $binaryPath = Resolve-MockBinaryPath
  $summary = @{
    provider   = $script:providerId
    operation  = $Operation
    parameters = if ($Params) { $Params } else { @{} }
  } | ConvertTo-Json -Depth 8

  $escaped = $summary -replace "'", "''"
  $arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-Command',
    "Write-Output '$escaped'"
  )

  return [pscustomobject]@{
    BinaryPath = $binaryPath
    Arguments  = $arguments
  }
}

function New-CompareVIProvider {
  $supportedOperations = @(
    'CloseLabVIEW',
    'CreateComparisonReport',
    'RunVI',
    'RunVIAnalyzer',
    'RunUnitTests',
    'MassCompile',
    'ExecuteBuildSpec'
  )
  $provider = [pscustomobject]@{
    Id                  = $script:providerId
    SupportedOperations = $supportedOperations
  }
  $null = $provider | Add-Member -MemberType ScriptMethod -Name SupportsOperation -Value {
    param($Operation)
    return $this.SupportedOperations -contains $Operation
  }
  $null = $provider | Add-Member -MemberType ScriptMethod -Name ResolveBinaryPath -Value {
    Resolve-MockBinaryPath
  }
  $null = $provider | Add-Member -MemberType ScriptMethod -Name GetInvocationPlan -Value {
    param($Operation,$Params)
    return New-MockInvocationPlan -Operation $Operation -Params $Params
  }
  return $provider
}

Export-ModuleMember -Function New-CompareVIProvider
