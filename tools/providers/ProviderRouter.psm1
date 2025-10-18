Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:specRoot = Join-Path $PSScriptRoot 'spec'
$script:providersSpecPath = Join-Path $script:specRoot 'providers.json'
$script:operationsSpecPath = Join-Path $script:specRoot 'operations.json'

$script:providersSpecCache = $null
$script:operationsSpecCache = $null
$script:providerInstanceCache = @{}

function Get-CompareVIProvidersSpec {
  if (-not $script:providersSpecCache) {
    if (-not (Test-Path -LiteralPath $script:providersSpecPath -PathType Leaf)) {
      throw "Provider specification not found at $script:providersSpecPath"
    }
    $raw = Get-Content -LiteralPath $script:providersSpecPath -Raw
    $script:providersSpecCache = ($raw | ConvertFrom-Json -Depth 8).providers
  }
  return $script:providersSpecCache
}

function Get-CompareVIOperationsSpec {
  if (-not $script:operationsSpecCache) {
    if (-not (Test-Path -LiteralPath $script:operationsSpecPath -PathType Leaf)) {
      throw "Operations specification not found at $script:operationsSpecPath"
    }
    $raw = Get-Content -LiteralPath $script:operationsSpecPath -Raw
    $script:operationsSpecCache = ($raw | ConvertFrom-Json -Depth 8).operations
  }
  return $script:operationsSpecCache
}

function Get-CompareVIProviderMetadata {
  param([string]$Id)
  $providers = Get-CompareVIProvidersSpec
  if (-not $Id) { return $providers }
  return $providers | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Get-CompareVIOperationMetadata {
  param([string]$Name)
  $operations = Get-CompareVIOperationsSpec
  if (-not $Name) { return $operations }
  return $operations | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Resolve-CompareVIProviderId {
  param([string]$Preferred)
  if ($Preferred) { return $Preferred }
  if ($env:LVCI_PROVIDER) { return $env:LVCI_PROVIDER }
  $default = Get-CompareVIProvidersSpec | Select-Object -First 1
  if (-not $default) { throw 'No provider metadata is registered in providers.json' }
  return $default.id
}

function Get-CompareVIProviderInstance {
  param([string]$Id)
  if (-not $Id) { throw 'Provider id cannot be empty.' }
  if ($script:providerInstanceCache.ContainsKey($Id)) {
    return $script:providerInstanceCache[$Id].Instance
  }
  $providerFolder = Join-Path $PSScriptRoot $Id
  if (-not (Test-Path -LiteralPath $providerFolder -PathType Container)) {
    throw "Provider folder not found: $providerFolder"
  }
  $modulePath = Join-Path $providerFolder 'Provider.psm1'
  if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "Provider module not found: $modulePath"
  }

  $module = Import-Module -Name $modulePath -PassThru -Force
  $factory = Get-Command -Module $module -Name 'New-CompareVIProvider' -ErrorAction Stop
  $instance = & $factory

  if (-not $instance) { throw "Provider factory for '$Id' returned null." }
  if (-not ($instance | Get-Member -Name Id)) {
    throw "Provider '$Id' must expose an Id member."
  }
  if ($instance.Id -ne $Id) {
    throw "Provider factory returned Id '$($instance.Id)' but expected '$Id'."
  }
  if (-not ($instance | Get-Member -Name SupportsOperation)) {
    throw "Provider '$Id' must expose a SupportsOperation method."
  }
  if (-not ($instance | Get-Member -Name GetInvocationPlan)) {
    throw "Provider '$Id' must expose a GetInvocationPlan method."
  }

  $script:providerInstanceCache[$Id] = @{
    Instance = $instance
    Module   = $module
  }
  return $script:providerInstanceCache[$Id].Instance
}

function Get-CompareVIProviderPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Operation,
    [hashtable]$Parameters,
    [string]$Provider
  )

  $providerId = Resolve-CompareVIProviderId -Preferred $Provider
  $providerMetadata = Get-CompareVIProviderMetadata -Id $providerId
  if (-not $providerMetadata) {
    throw "Unknown provider id '$providerId'. Update tools/providers/spec/providers.json to register it."
  }
  $operationMetadata = Get-CompareVIOperationMetadata -Name $Operation
  if (-not $operationMetadata) {
    throw "Unknown operation '$Operation'. Update tools/providers/spec/operations.json to register it."
  }

  $instance = Get-CompareVIProviderInstance -Id $providerId
  $supports = $instance.SupportsOperation.Invoke($Operation)
  if (-not $supports) {
    throw "Provider '$providerId' does not support operation '$Operation'."
  }

  $paramTable = if ($Parameters) { $Parameters } else { @{} }
  $plan = $instance.GetInvocationPlan.Invoke($Operation, $paramTable)
  if (-not $plan) {
    throw "Provider '$providerId' returned an empty invocation plan for operation '$Operation'."
  }
  if (-not ($plan | Get-Member -Name BinaryPath)) {
    throw "Invocation plan from provider '$providerId' is missing BinaryPath."
  }
  if (-not ($plan | Get-Member -Name Arguments)) {
    throw "Invocation plan from provider '$providerId' is missing Arguments."
  }

  return [pscustomobject]@{
    provider  = $providerMetadata
    operation = $operationMetadata
    binary    = $plan.BinaryPath
    arguments = @($plan.Arguments)
  }
}

Export-ModuleMember -Function `
  Get-CompareVIProvidersSpec,`
  Get-CompareVIOperationsSpec,`
  Get-CompareVIProviderMetadata,`
  Get-CompareVIOperationMetadata,`
  Get-CompareVIProviderPlan
