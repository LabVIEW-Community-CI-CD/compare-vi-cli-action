Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LVRepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    $root = git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($root) { return $root.Trim() }
  } catch {}
  return (Resolve-Path -LiteralPath $StartPath).Path
}

$script:RepoRoot = Resolve-LVRepoRoot
$script:SpecPath = Join-Path $PSScriptRoot 'providers/spec/operations.json'
if (-not (Test-Path -LiteralPath $script:SpecPath -PathType Leaf)) {
  throw "LabVIEW CLI operations spec not found at $script:SpecPath"
}
$script:OperationSpec = Get-Content -LiteralPath $script:SpecPath -Raw | ConvertFrom-Json -ErrorAction Stop
$script:Providers = @{}

function Get-LVOperationNames {
  $script:OperationSpec.operations.name
}

function Get-LVOperationSpec {
  param([Parameter(Mandatory)][string]$Operation)
  $spec = $script:OperationSpec.operations | Where-Object { $_.name -eq $Operation }
  if (-not $spec) {
    throw "Unknown LabVIEW CLI operation '$Operation'. Available: $($script:OperationSpec.operations.name -join ', ')"
  }
  return $spec
}

function Register-LVProvider {
  param(
    [Parameter(Mandatory)][object]$Provider
  )
  foreach ($member in @('Name','ResolveBinaryPath','Supports','BuildArgs')) {
    if (-not ($Provider | Get-Member -Name $member)) {
      throw "Provider registration failed: Missing required method '$member'."
    }
  }
  $name = $Provider.Name()
  if (-not $name) { throw "Provider registration failed: Name() returned empty." }
  $script:Providers[$name.ToLowerInvariant()] = $Provider
}

function Get-LVProviders {
  return $script:Providers.GetEnumerator() | ForEach-Object { $_.Value }
}

function Get-LVProviderByName {
  param([Parameter(Mandatory)][string]$Name)
  $key = $Name.ToLowerInvariant()
  if ($script:Providers.ContainsKey($key)) { return $script:Providers[$key] }
  return $null
}

function Import-LVProviderModules {
  $providerRoot = Join-Path $PSScriptRoot 'providers'
  if (-not (Test-Path -LiteralPath $providerRoot -PathType Container)) { return }
  $modules = Get-ChildItem -Path $providerRoot -Directory -ErrorAction SilentlyContinue
  foreach ($modDir in $modules) {
    $modulePath = Join-Path $modDir.FullName 'Provider.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { continue }
    try {
      $moduleInfo = Import-Module $modulePath -Force -PassThru
      $moduleName = $moduleInfo.Name
      $command = Get-Command -Name 'New-LVProvider' -Module $moduleName -ErrorAction Stop
      $provider = & $command
      if (-not $provider) { throw "New-LVProvider returned null." }
      Register-LVProvider -Provider $provider
    } catch {
      Write-Warning ("Failed to import provider from {0}: {1}" -f $modulePath, $_.Exception.Message)
    }
  }
}

Import-LVProviderModules

$script:LabVIEWPidTrackerModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'LabVIEWPidTracker.psm1'
$script:LabVIEWPidTrackerLoaded = $false
$script:LabVIEWPidTrackerPath = $null
$script:LabVIEWPidTrackerRelativePath = $null
$script:LabVIEWPidTrackerState = $null
$script:LabVIEWPidTrackerInitialState = $null
$script:LabVIEWPidTrackerFinalized = $false
$script:LabVIEWPidTrackerFinalState = $null
$script:LabVIEWPidTrackerFinalizedSource = $null
$script:LabVIEWPidTrackerFinalContext = $null
$script:LabVIEWPidTrackerFinalContextSource = $null
$script:LabVIEWPidTrackerFinalContextDetail = $null

if (Test-Path -LiteralPath $script:LabVIEWPidTrackerModule -PathType Leaf) {
  try {
    Import-Module $script:LabVIEWPidTrackerModule -Force -ErrorAction Stop
    $script:LabVIEWPidTrackerLoaded = $true
  } catch {
    Write-Warning ("LabVIEW CLI: failed to import LabVIEW PID tracker module: {0}" -f $_.Exception.Message)
    $script:LabVIEWPidTrackerLoaded = $false
  }
}

function Convert-ToAbsolutePath {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
  try {
    $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction Stop
    return $resolved.Path
  } catch {
    try {
      if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
      }
      return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
    } catch {
      return $PathValue
    }
  }
}

function Resolve-LVNormalizedParams {
  param(
    [Parameter(Mandatory)][object]$OperationSpec,
    [Parameter()][hashtable]$Params
  )
  $Params = $Params ?? @{}
  $normalized = @{}
  foreach ($paramSpec in $OperationSpec.parameters) {
    $id = [string]$paramSpec.id
    $value = $null
    if ($Params.ContainsKey($id)) {
      $value = $Params[$id]
    } else {
      $altKey = $Params.Keys | Where-Object { $_.ToString().ToLowerInvariant() -eq $id.ToLowerInvariant() } | Select-Object -First 1
      if ($altKey) { $value = $Params[$altKey] }
    }
    if (-not $value -and ($paramSpec.PSObject.Properties.Name -contains 'env') -and $paramSpec.env) {
      foreach ($envName in $paramSpec.env) {
        $envValue = [System.Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
          $value = $envValue
          break
        }
      }
    }
    if (-not $value -and $paramSpec.PSObject.Properties.Name -contains 'default') {
      $value = $paramSpec.default
    }
    if ($paramSpec.required -and ([string]::IsNullOrWhiteSpace([string]$value))) {
      throw "Missing required parameter '$id' for operation '$($OperationSpec.name)'."
    }
    if ($null -ne $value) {
      switch ($paramSpec.type) {
        'path' {
          $normalized[$id] = Convert-ToAbsolutePath $value
        }
        'bool' {
          if ($value -is [bool]) {
            $normalized[$id] = $value
          } else {
            $normalized[$id] = [System.Convert]::ToBoolean($value)
          }
        }
        'int' {
          $normalized[$id] = [int]$value
        }
        'enum' {
          $allowed = @($paramSpec.values)
          $chosen = [string]$value
          if ($allowed.Count -gt 0 -and -not ($allowed | Where-Object { $_ -ieq $chosen })) {
            throw "Parameter '$id' value '$chosen' not in allowed set ($($allowed -join ', '))."
          }
          # preserve canonical casing if match found
          $canonical = $allowed | Where-Object { $_ -ieq $chosen } | Select-Object -First 1
          $normalized[$id] = $canonical ?? $chosen
        }
        'array' {
          if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            $normalized[$id] = @($value)
          } elseif ([string]::IsNullOrWhiteSpace([string]$value)) {
            $normalized[$id] = @()
          } else {
            $normalized[$id] = @([string]$value)
          }
        }
        default {
          $normalized[$id] = [string]$value
        }
      }
    }
  }
  return $normalized
}

function Select-LVProvider {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [Parameter()][string]$RequestedProvider
  )
  $providers = @()
  if ($RequestedProvider -and $RequestedProvider -ne 'auto') {
    $explicit = Get-LVProviderByName $RequestedProvider
    if (-not $explicit) { throw "Requested provider '$RequestedProvider' is not registered." }
    $providers = @($explicit)
  } else {
    $envProvider = $env:LVCLI_PROVIDER
    if ($envProvider -and $envProvider -ne 'auto') {
      $explicit = Get-LVProviderByName $envProvider
      if ($explicit) { $providers += $explicit }
    }
    if (-not $providers) {
      $providers = Get-LVProviders
    }
  }
  if (-not $providers -or $providers.Count -eq 0) {
    throw "No LabVIEW CLI providers registered."
  }
  foreach ($provider in $providers) {
    try {
      $binary = $provider.ResolveBinaryPath()
      if ([string]::IsNullOrWhiteSpace($binary) -or -not (Test-Path -LiteralPath $binary -PathType Leaf)) { continue }
      if (-not ($provider.Supports($Operation))) { continue }
        return [pscustomobject]@{
          Provider     = $provider
          ProviderName = $provider.Name()
          Binary       = (Resolve-Path -LiteralPath $binary).Path
        }
    } catch {
      Write-Verbose ("Provider {0} selection failed: {1}" -f $provider.Name(), $_.Exception.Message)
    }
  }
  $names = ($providers | ForEach-Object { $_.Name() }) -join ', '
  throw "No registered provider can execute operation '$Operation'. Checked: $names"
}

  function Set-LVHeadlessEnv {
    $guard = @{}
    foreach ($pair in (@{'LV_SUPPRESS_UI'='1'; 'LV_NO_ACTIVATE'='1'; 'LV_CURSOR_RESTORE'='1'}).GetEnumerator()) {
      $existing = [System.Environment]::GetEnvironmentVariable($pair.Key)
      if ($existing) { $guard[$pair.Key] = $existing }
      [System.Environment]::SetEnvironmentVariable($pair.Key, $pair.Value)
    }
  if (-not [System.Environment]::GetEnvironmentVariable('LV_IDLE_WAIT_SECONDS')) {
    [System.Environment]::SetEnvironmentVariable('LV_IDLE_WAIT_SECONDS','2')
    $guard['LV_IDLE_WAIT_SECONDS'] = $null
  }
  if (-not [System.Environment]::GetEnvironmentVariable('LV_IDLE_MAX_WAIT_SECONDS')) {
    [System.Environment]::SetEnvironmentVariable('LV_IDLE_MAX_WAIT_SECONDS','5')
    $guard['LV_IDLE_MAX_WAIT_SECONDS'] = $null
  }
  return $guard
}

function Restore-LVHeadlessEnv {
  param([hashtable]$Guard)
  if (-not $Guard) { return }
  foreach ($key in $Guard.Keys) {
    $value = $Guard[$key]
    [System.Environment]::SetEnvironmentVariable($key, $value)
  }
}

function Write-LVOperationEvent {
  param(
    [Parameter(Mandatory)][hashtable]$EventData
  )
  try {
    $resultsDir = Join-Path $script:RepoRoot 'tests/results'
    if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
      New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    }
    $cliDir = Join-Path $resultsDir '_cli'
    if (-not (Test-Path -LiteralPath $cliDir -PathType Container)) {
      New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
    }
    $eventFile = Join-Path $cliDir 'operation-events.ndjson'
    if (-not $EventData.ContainsKey('timestamp')) {
      $EventData['timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
    }
    ($EventData | ConvertTo-Json -Compress) | Add-Content -Path $eventFile
  } catch {
    Write-Verbose ("Failed to write CLI event: {0}" -f $_.Exception.Message)
  }
}

function Initialize-LabVIEWCliPidTracker {
  if (-not $script:LabVIEWPidTrackerLoaded) { return }
  if ($script:LabVIEWPidTrackerState) { return }

  $resultsDir = Join-Path $script:RepoRoot 'tests/results'
  $cliDir = Join-Path $resultsDir '_cli'
  $agentDir = Join-Path $cliDir '_agent'

  try {
    if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) {
      New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
    }
  } catch {
    Write-Warning ("LabVIEW CLI: failed to prepare LabVIEW PID tracker directory: {0}" -f $_.Exception.Message)
    $script:LabVIEWPidTrackerLoaded = $false
    $script:LabVIEWPidTrackerPath = $null
    $script:LabVIEWPidTrackerRelativePath = $null
    return
  }

  $trackerPath = Join-Path $agentDir 'labview-pid.json'

  $script:LabVIEWPidTrackerState = $null
  $script:LabVIEWPidTrackerInitialState = $null
  $script:LabVIEWPidTrackerFinalState = $null
  $script:LabVIEWPidTrackerFinalized = $false
  $script:LabVIEWPidTrackerFinalizedSource = $null
  $script:LabVIEWPidTrackerFinalContext = $null
  $script:LabVIEWPidTrackerFinalContextSource = $null
  $script:LabVIEWPidTrackerFinalContextDetail = $null

  try {
    $state = Start-LabVIEWPidTracker -TrackerPath $trackerPath -Source 'labview-cli:init'
    $script:LabVIEWPidTrackerState = $state
    $script:LabVIEWPidTrackerInitialState = $state
    $script:LabVIEWPidTrackerPath = $trackerPath
    $script:LabVIEWPidTrackerRelativePath = 'tests/results/_cli/_agent/labview-pid.json'
    if ($state -and $state.PSObject.Properties['Pid'] -and $state.Pid) {
      $modeText = if ($state.Reused) { 'Reusing existing' } else { 'Tracking detected' }
      Write-Host ("[labview-pid] {0} LabVIEW.exe PID {1}." -f $modeText, $state.Pid) -ForegroundColor DarkGray
    }
  } catch {
    Write-Warning ("LabVIEW CLI: failed to start LabVIEW PID tracker: {0}" -f $_.Exception.Message)
    $script:LabVIEWPidTrackerLoaded = $false
    $script:LabVIEWPidTrackerPath = $null
    $script:LabVIEWPidTrackerRelativePath = $null
    $script:LabVIEWPidTrackerState = $null
    $script:LabVIEWPidTrackerInitialState = $null
  }
}

function Finalize-LabVIEWCliPidTracker {
  param(
    [string]$Source,
    [string]$Operation,
    [string]$Provider,
    [Nullable[int]]$ExitCode,
    [Nullable[bool]]$TimedOut,
    [string[]]$Args,
    [Nullable[double]]$ElapsedSeconds,
    [string]$Binary,
    [string]$ErrorMessage
  )

  if (-not $script:LabVIEWPidTrackerLoaded) { return }
  if (-not $script:LabVIEWPidTrackerPath) { return }
  if ($script:LabVIEWPidTrackerFinalized) { return }

  $context = [ordered]@{ stage = if ($Source) { $Source } else { 'labview-cli:summary' } }
  if ($Operation) { $context.operation = $Operation }
  if ($Provider) { $context.provider = $Provider }
  if ($PSBoundParameters.ContainsKey('ExitCode') -and $ExitCode -ne $null) {
    $context.exitCode = [int]$ExitCode
  }
  if ($PSBoundParameters.ContainsKey('TimedOut')) { $context.timedOut = [bool]$TimedOut }
  if ($Args) { $context.args = @($Args) }
  if ($PSBoundParameters.ContainsKey('ElapsedSeconds') -and $ElapsedSeconds -ne $null) {
    $context.elapsedSeconds = [double]$ElapsedSeconds
  }
  if ($PSBoundParameters.ContainsKey('Binary') -and $Binary) { $context.binary = $Binary }
  if ($PSBoundParameters.ContainsKey('ErrorMessage') -and $ErrorMessage) { $context.error = $ErrorMessage }

  $stopArgs = @{ TrackerPath = $script:LabVIEWPidTrackerPath; Source = $context.stage }
  if (
    $script:LabVIEWPidTrackerState -and
    $script:LabVIEWPidTrackerState.PSObject.Properties['Pid'] -and
    $script:LabVIEWPidTrackerState.Pid
  ) {
    $stopArgs.Pid = $script:LabVIEWPidTrackerState.Pid
  }
  if ($context.Count -gt 0) { $stopArgs.Context = [pscustomobject]$context }

  try {
    $finalState = Stop-LabVIEWPidTracker @stopArgs
    $script:LabVIEWPidTrackerFinalState = $finalState
    $script:LabVIEWPidTrackerFinalizedSource = $context.stage
    if ($finalState -and $finalState.PSObject.Properties['Context'] -and $finalState.Context) {
      $script:LabVIEWPidTrackerFinalContext = $finalState.Context
      if ($finalState.PSObject.Properties['ContextSource'] -and $finalState.ContextSource) {
        $script:LabVIEWPidTrackerFinalContextSource = [string]$finalState.ContextSource
        $script:LabVIEWPidTrackerFinalContextDetail = [string]$finalState.ContextSource
      }
    }
    } catch {
      Write-Warning (
        "LabVIEW CLI: failed to finalize LabVIEW PID tracker: {0}" -f $_.Exception.Message
      )
      if ($context) {
        try {
          $script:LabVIEWPidTrackerFinalContext = Resolve-LabVIEWPidContext -Input $context
        } catch {
          $script:LabVIEWPidTrackerFinalContext = $context
        }
        $script:LabVIEWPidTrackerFinalContextSource = $context.stage
        $script:LabVIEWPidTrackerFinalContextDetail = $context.stage
      }
    } finally {
      if ($context -and -not $script:LabVIEWPidTrackerFinalContext) {
        try {
          $script:LabVIEWPidTrackerFinalContext = Resolve-LabVIEWPidContext -Input $context
        } catch {
          $script:LabVIEWPidTrackerFinalContext = $context
        }
        if (-not $script:LabVIEWPidTrackerFinalContextSource) {
          $script:LabVIEWPidTrackerFinalContextSource = $context.stage
        }
        if (-not $script:LabVIEWPidTrackerFinalContextDetail) {
          $script:LabVIEWPidTrackerFinalContextDetail = $context.stage
        }
      }
      if (-not $script:LabVIEWPidTrackerFinalizedSource) { $script:LabVIEWPidTrackerFinalizedSource = $context.stage }
      if (-not $script:LabVIEWPidTrackerFinalContextDetail -and $script:LabVIEWPidTrackerFinalContextSource) {
        $script:LabVIEWPidTrackerFinalContextDetail = $script:LabVIEWPidTrackerFinalContextSource
      }
      $script:LabVIEWPidTrackerFinalized = $true
      $script:LabVIEWPidTrackerState = $null
    }

  return $script:LabVIEWPidTrackerFinalState
}

function Add-LabVIEWCliPidTrackerToResult {
  param([pscustomobject]$Result)
  if (-not $Result) { return }

  $payload = [ordered]@{ enabled = [bool]$script:LabVIEWPidTrackerLoaded }
  if ($script:LabVIEWPidTrackerPath) { $payload['path'] = $script:LabVIEWPidTrackerPath }
  if ($script:LabVIEWPidTrackerRelativePath) { $payload['relativePath'] = $script:LabVIEWPidTrackerRelativePath }

  if ($script:LabVIEWPidTrackerInitialState) {
    $initial = [ordered]@{}
    if (
      $script:LabVIEWPidTrackerInitialState.PSObject.Properties['Pid'] -and
      $script:LabVIEWPidTrackerInitialState.Pid
    ) {
      try { $initial['pid'] = [int]$script:LabVIEWPidTrackerInitialState.Pid } catch { $initial['pid'] = $null }
    } else {
      $initial['pid'] = $null
    }
    if ($script:LabVIEWPidTrackerInitialState.PSObject.Properties['Running']) {
      try {
        $initial['running'] = [bool]$script:LabVIEWPidTrackerInitialState.Running
      } catch {
        $initial['running'] = $null
      }
    }
    if ($script:LabVIEWPidTrackerInitialState.PSObject.Properties['Reused']) {
      try {
        $initial['reused'] = [bool]$script:LabVIEWPidTrackerInitialState.Reused
      } catch {
        $initial['reused'] = $null
      }
    }
    if ($script:LabVIEWPidTrackerInitialState.PSObject.Properties['Candidates']) {
      $initial['candidates'] = @(
        $script:LabVIEWPidTrackerInitialState.Candidates | Where-Object { $_ -ne $null }
      )
    }
    if (
      $script:LabVIEWPidTrackerInitialState.PSObject.Properties['Observation'] -and
      $script:LabVIEWPidTrackerInitialState.Observation
    ) {
      $initial['observation'] = $script:LabVIEWPidTrackerInitialState.Observation
    }
    if ($initial.Count -gt 0) { $payload['initial'] = [pscustomobject]$initial }
  }

  if ($script:LabVIEWPidTrackerFinalized) {
    $final = [ordered]@{}
    if (
      $script:LabVIEWPidTrackerFinalState -and
      $script:LabVIEWPidTrackerFinalState.PSObject.Properties['Pid'] -and
      $script:LabVIEWPidTrackerFinalState.Pid
    ) {
      try { $final['pid'] = [int]$script:LabVIEWPidTrackerFinalState.Pid } catch { $final['pid'] = $null }
    } elseif (
      $script:LabVIEWPidTrackerInitialState -and
      $script:LabVIEWPidTrackerInitialState.PSObject.Properties['Pid'] -and
      $script:LabVIEWPidTrackerInitialState.Pid
    ) {
      try { $final['pid'] = [int]$script:LabVIEWPidTrackerInitialState.Pid } catch { $final['pid'] = $null }
    } else {
      $final['pid'] = $null
    }
    if (
      $script:LabVIEWPidTrackerFinalState -and
      $script:LabVIEWPidTrackerFinalState.PSObject.Properties['Running']
    ) {
      try { $final['running'] = [bool]$script:LabVIEWPidTrackerFinalState.Running } catch { $final['running'] = $null }
    }
    if (
      $script:LabVIEWPidTrackerFinalState -and
      $script:LabVIEWPidTrackerFinalState.PSObject.Properties['Reused']
    ) {
      try { $final['reused'] = [bool]$script:LabVIEWPidTrackerFinalState.Reused } catch { $final['reused'] = $null }
    } elseif (
      $script:LabVIEWPidTrackerInitialState -and
      $script:LabVIEWPidTrackerInitialState.PSObject.Properties['Reused']
    ) {
      try { $final['reused'] = [bool]$script:LabVIEWPidTrackerInitialState.Reused } catch { $final['reused'] = $null }
    }
    if (
      $script:LabVIEWPidTrackerFinalState -and
      $script:LabVIEWPidTrackerFinalState.PSObject.Properties['Observation'] -and
      $script:LabVIEWPidTrackerFinalState.Observation
    ) {
      $final['observation'] = $script:LabVIEWPidTrackerFinalState.Observation
    }
    if ($script:LabVIEWPidTrackerFinalizedSource) {
      $final['finalizedSource'] = $script:LabVIEWPidTrackerFinalizedSource
    }
    if (
      $script:LabVIEWPidTrackerFinalState -and
      $script:LabVIEWPidTrackerFinalState.PSObject.Properties['Context'] -and
      $script:LabVIEWPidTrackerFinalState.Context
    ) {
      $final['context'] = $script:LabVIEWPidTrackerFinalState.Context
    }
    if (
      $script:LabVIEWPidTrackerFinalState -and
      $script:LabVIEWPidTrackerFinalState.PSObject.Properties['ContextSource'] -and
      $script:LabVIEWPidTrackerFinalState.ContextSource
    ) {
      $final['contextSource'] = [string]$script:LabVIEWPidTrackerFinalState.ContextSource
    }
    if ($script:LabVIEWPidTrackerFinalContext) {
      $final['context'] = $script:LabVIEWPidTrackerFinalContext
    }
    if ($script:LabVIEWPidTrackerFinalContextSource) {
      $final['contextSource'] = $script:LabVIEWPidTrackerFinalContextSource
    }
    if ($script:LabVIEWPidTrackerFinalContextDetail) {
      $final['contextSourceDetail'] = $script:LabVIEWPidTrackerFinalContextDetail
    }
    if ($final.Count -gt 0) { $payload['final'] = [pscustomobject]$final }
  }

  if ($Result.PSObject.Properties['labviewPidTracker']) {
    $Result.labviewPidTracker = [pscustomobject]$payload
  } else {
    Add-Member -InputObject $Result -Name labviewPidTracker -MemberType NoteProperty -Value ([pscustomobject]$payload)
  }
}

function Invoke-LVOperation {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Operation,
    [Parameter()][hashtable]$Params,
    [string]$Provider = 'auto',
    [switch]$Preview,
    [int]$TimeoutSeconds = 300
  )

  $spec = Get-LVOperationSpec -Operation $Operation
  $normalized = Resolve-LVNormalizedParams -OperationSpec $spec -Params $Params
  $selection = Select-LVProvider -Operation $Operation -RequestedProvider $Provider
  $provider = $selection.Provider
  $providerObject = $selection.Provider
  $providerName = $selection.ProviderName
  $binary = $selection.Binary
  if (-not $providerName -and $provider -and -not ($provider -is [string])) {
    try { $providerName = $provider.Name() } catch {}
  }
  if ($provider -is [string]) {
    $lookupName = if (-not [string]::IsNullOrWhiteSpace($providerName)) { $providerName } else { $provider.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($lookupName)) {
      Write-Verbose ("LabVIEW CLI provider fallback lookup for '{0}'." -f $lookupName)
      if (-not $providerName) { $providerName = $lookupName }
      $fallbackProvider = Get-LVProviderByName $lookupName
      if (-not $fallbackProvider) {
        $fallbackProvider = Get-LVProviders | Where-Object { $_.Name() -eq $lookupName } | Select-Object -First 1
      }
      if ($fallbackProvider) {
        Write-Verbose ("LabVIEW CLI provider '{0}' resolved via fallback (type {1})." -f $lookupName, $fallbackProvider.GetType().FullName)
        $providerObject = $fallbackProvider
      }
    }
  }
  $providerLabel = if ($providerName) { $providerName } elseif ($Provider) { $Provider } else { 'auto' }
  if ($null -eq $providerObject) { throw "Provider '$providerLabel' could not be resolved." }
  try {
    if ($providerObject -and ($providerObject | Get-Member -Name 'Name' -ErrorAction SilentlyContinue)) {
      $providerLabel = $providerObject.Name()
      if (-not $providerName) { $providerName = $providerLabel }
    }
  } catch {}
  Write-Verbose ("LabVIEW CLI provider '{0}' resolved to type {1}" -f $providerLabel, ($providerObject.GetType().FullName))
  if ($providerObject -and ($providerObject | Get-Member -Name 'Validate')) {
    $providerObject.Validate($Operation, $normalized)
  }
  $arguments = $providerObject.BuildArgs($Operation, $normalized)
  $commandLine = "$binary " + ($arguments -join ' ')
  $result = [ordered]@{
    provider        = if ($providerObject -and ($providerObject | Get-Member -Name 'Name' -ErrorAction SilentlyContinue)) { $providerObject.Name() } else { $providerLabel }
    operation       = $Operation
    cliPath         = $binary
    args            = @($arguments)
    command         = $commandLine
    normalizedParams= $normalized
  }
  if ($Preview) { return [pscustomobject]$result }

  Initialize-LabVIEWCliPidTracker

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $binary
  foreach ($arg in $arguments) { $psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.UseShellExecute = $false

  $guard = $null
  $process = $null
  $stdout = ''
  $stderr = ''
  $sw = $null
  $timedOut = $false
  $exitCode = $null
  $elapsedSeconds = $null
  $finalizeSource = 'labview-cli:operation'
  $errorMessage = $null

  try {
    $guard = Set-LVHeadlessEnv
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $process = [System.Diagnostics.Process]::Start($psi)
      if (-not $process) { throw "Failed to start process '$binary'." }
      if (-not $process.WaitForExit([Math]::Max(1,$TimeoutSeconds) * 1000)) {
        $timedOut = $true
        try { $process.Kill($true) } catch {}
        throw "Operation '$Operation' timed out after $TimeoutSeconds second(s)."
      }
      $stdout = $process.StandardOutput.ReadToEnd()
      $stderr = $process.StandardError.ReadToEnd()
      $exitCode = $process.ExitCode
      if ($sw) { $elapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds,3) }
    } catch {
      $errorMessage = $_.Exception.Message
      $finalizeSource = 'labview-cli:error'
      throw
    } finally {
      if ($sw) { $sw.Stop() }
      if ($process) { $process.Dispose() }
      if ($guard) { Restore-LVHeadlessEnv -Guard $guard }
      if ($script:LabVIEWPidTrackerLoaded -and $script:LabVIEWPidTrackerPath) {
        $trackerElapsed = $elapsedSeconds
        if (-not $trackerElapsed -and $sw) {
          try { $trackerElapsed = [Math]::Round($sw.Elapsed.TotalSeconds,3) } catch { $trackerElapsed = $null }
        }
        try {
          Finalize-LabVIEWCliPidTracker -Source $finalizeSource -Operation $Operation -Provider $result.provider -ExitCode $exitCode -TimedOut:$timedOut -Args $result.args -ElapsedSeconds $trackerElapsed -Binary $binary -ErrorMessage $errorMessage | Out-Null
        } catch {
          Write-Verbose ("LabVIEW CLI: tracker finalization failed: {0}" -f $_.Exception.Message)
        }
      }
    }
  } catch {
    throw
  }

  $result.exitCode = $exitCode
  $result.elapsedSeconds = $elapsedSeconds
  $result.stdout = $stdout
  $result.stderr = $stderr
  $result.ok = (-not $timedOut -and $exitCode -eq 0)

  Write-LVOperationEvent -EventData @{
    provider = $result.provider
    operation = $Operation
    exitCode = $exitCode
    seconds = $result.elapsedSeconds
    args = $result.args
    timedOut = $timedOut
  }

  Add-LabVIEWCliPidTrackerToResult $result

  return [pscustomobject]$result
}

function Invoke-LVCreateComparisonReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [string]$ReportPath,
    [ValidateSet('HTMLSingleFile','HTML','XML','Text','Word')]
    [string]$ReportType,
    [string]$Provider = 'auto',
    [switch]$Preview
  )

  $params = @{
    vi1 = $BaseVi
    vi2 = $HeadVi
  }
  if ($PSBoundParameters.ContainsKey('ReportPath') -and $ReportPath) {
    $params.reportPath = $ReportPath
  }
  if ($PSBoundParameters.ContainsKey('ReportType') -and $ReportType) {
    $params.reportType = $ReportType
  }
  Invoke-LVOperation -Operation 'CreateComparisonReport' -Params $params -Provider $Provider -Preview:$Preview
}

function Invoke-LVRunVI {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ViPath,
    [object[]]$Arguments,
    [switch]$ShowFrontPanel,
    [switch]$AbortOnError,
    [string]$Provider = 'auto',
    [switch]$Preview
  )

  $params = @{ viPath = $ViPath }
  if ($PSBoundParameters.ContainsKey('Arguments') -and $Arguments) { $params.arguments = @($Arguments) }
  if ($PSBoundParameters.ContainsKey('ShowFrontPanel')) { $params.showFP = $ShowFrontPanel.IsPresent }
  if ($PSBoundParameters.ContainsKey('AbortOnError')) { $params.abortOnError = $AbortOnError.IsPresent }

  Invoke-LVOperation -Operation 'RunVI' -Params $params -Provider $Provider -Preview:$Preview
}

function Invoke-LVRunVIAnalyzer {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateSet('HTML','XML','Text')]
    [string]$ReportSaveType,
    [string]$ConfigPassword,
    [string]$Provider = 'auto',
    [switch]$Preview
  )

  $params = @{
    configPath = $ConfigPath
    reportPath = $ReportPath
  }
  if ($PSBoundParameters.ContainsKey('ReportSaveType') -and $ReportSaveType) { $params.reportSaveType = $ReportSaveType }
  if ($PSBoundParameters.ContainsKey('ConfigPassword') -and $ConfigPassword) { $params.configPassword = $ConfigPassword }

  Invoke-LVOperation -Operation 'RunVIAnalyzer' -Params $params -Provider $Provider -Preview:$Preview
}

function Invoke-LVRunUnitTests {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$JUnitReportPath,
    [string]$Provider = 'auto',
    [switch]$Preview
  )

  $params = @{
    projectPath    = $ProjectPath
    junitReportPath= $JUnitReportPath
  }
  Invoke-LVOperation -Operation 'RunUnitTests' -Params $params -Provider $Provider -Preview:$Preview
}

function Invoke-LVMassCompile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$DirectoryToCompile,
    [string]$MassCompileLogFile,
    [switch]$AppendToMassCompileLog,
    [int]$NumOfVIsToCache,
    [switch]$ReloadLVSBs,
    [string]$Provider = 'auto',
    [switch]$Preview
  )

  $params = @{ directoryToCompile = $DirectoryToCompile }
  if ($PSBoundParameters.ContainsKey('MassCompileLogFile') -and $MassCompileLogFile) { $params.massCompileLogFile = $MassCompileLogFile }
  if ($PSBoundParameters.ContainsKey('AppendToMassCompileLog')) { $params.appendToMassCompileLog = $AppendToMassCompileLog.IsPresent }
  if ($PSBoundParameters.ContainsKey('NumOfVIsToCache')) { $params.numOfVIsToCache = $NumOfVIsToCache }
  if ($PSBoundParameters.ContainsKey('ReloadLVSBs')) { $params.reloadLVSBs = $ReloadLVSBs.IsPresent }

  Invoke-LVOperation -Operation 'MassCompile' -Params $params -Provider $Provider -Preview:$Preview
}

function Invoke-LVExecuteBuildSpec {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$BuildSpecName,
    [string]$TargetName,
    [string]$Provider = 'auto',
    [switch]$Preview
  )

  $params = @{
    projectPath   = $ProjectPath
    buildSpecName = $BuildSpecName
  }
  if ($PSBoundParameters.ContainsKey('TargetName') -and $TargetName) { $params.targetName = $TargetName }

  Invoke-LVOperation -Operation 'ExecuteBuildSpec' -Params $params -Provider $Provider -Preview:$Preview
}

Export-ModuleMember -Function `
  Invoke-LVCreateComparisonReport, `
  Invoke-LVRunVI, `
  Invoke-LVRunVIAnalyzer, `
  Invoke-LVRunUnitTests, `
  Invoke-LVMassCompile, `
  Invoke-LVExecuteBuildSpec, `
  Invoke-LVOperation, `
  Get-LVOperationNames, `
  Get-LVOperationSpec, `
  Register-LVProvider, `
  Get-LVProviders, `
  Get-LVProviderByName
