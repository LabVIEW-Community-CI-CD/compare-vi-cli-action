#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-IconEditorRepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    $root = git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($root) {
      return (Resolve-Path -LiteralPath $root.Trim()).Path
    }
  } catch {
    # fall back to supplied path
  }
  return (Resolve-Path -LiteralPath $StartPath).Path
}

function Resolve-IconEditorRoot {
  param([string]$RepoRoot)
  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  }
  $root = Join-Path $RepoRoot 'vendor' 'icon-editor'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Icon editor root not found at '$root'. Vendor the labview-icon-editor repository first."
  }
  return (Resolve-Path -LiteralPath $root).Path
}

function Get-IconEditorDevModeStatePath {
  param([string]$RepoRoot)
  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  }
  return Join-Path $RepoRoot 'tests' 'results' '_agent' 'icon-editor' 'dev-mode-state.json'
}

function Get-IconEditorDevModeState {
  param([string]$RepoRoot)
  $statePath = Get-IconEditorDevModeStatePath -RepoRoot $RepoRoot
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    return [pscustomobject]@{
      Active    = $null
      UpdatedAt = $null
      Source    = $null
      Path      = $statePath
    }
  }

  try {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Failed to parse icon editor dev-mode state file at '$statePath': $($_.Exception.Message)"
  }

  return [pscustomobject]@{
    Active    = $state.active
    UpdatedAt = $state.updatedAt
    Source    = $state.source
    Path      = $statePath
  }
}

function Set-IconEditorDevModeState {
  param(
    [Parameter(Mandatory)][bool]$Active,
    [string]$RepoRoot,
    [string]$Source
  )

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  $statePath = Get-IconEditorDevModeStatePath -RepoRoot $RepoRoot
  $stateDir = Split-Path -Parent $statePath
  if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
  }

  $payload = [ordered]@{
    schema    = 'icon-editor/dev-mode-state@v1'
    updatedAt = (Get-Date).ToString('o')
    active    = [bool]$Active
    source    = $Source
  }

  $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
  return Get-IconEditorDevModeState -RepoRoot $RepoRoot
}

function Invoke-IconEditorDevModeScript {
  param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [string[]]$ArgumentList,
    [string]$RepoRoot,
    [string]$IconEditorRoot
  )

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  if (-not $IconEditorRoot) {
    $IconEditorRoot = Resolve-IconEditorRoot -RepoRoot $RepoRoot
  } else {
    $IconEditorRoot = (Resolve-Path -LiteralPath $IconEditorRoot).Path
  }

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Icon editor dev-mode script not found at '$ScriptPath'."
  }

  Import-Module (Join-Path $RepoRoot 'tools' 'VendorTools.psm1') -Force
  $gCliPath = Resolve-GCliPath
  if (-not $gCliPath) {
    throw "Unable to locate g-cli.exe. Update configs/labview-paths.local.json or set GCLI_EXE_PATH so the dev-mode helper can find g-cli."
  }

  $scriptDirectory = Split-Path -Parent $ScriptPath
  $previousLocation = Get-Location
  $previousPath = $env:Path
  $gCliDirectory = Split-Path -Parent $gCliPath

  $pwshCmd = Get-Command pwsh -ErrorAction Stop
  $args = if ($ArgumentList -and $ArgumentList.Count -gt 0) { $ArgumentList } else { @('-RelativePath', $IconEditorRoot) }

  Set-Location -LiteralPath $scriptDirectory
  try {
    if ($previousPath -notlike "$gCliDirectory*") {
      $env:Path = "$gCliDirectory;$previousPath"
    }

    & $pwshCmd.Source -NoLogo -NoProfile -File $ScriptPath @args
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "Dev-mode script '$ScriptPath' exited with code $exitCode."
    }
  }
  finally {
    Set-Location -LiteralPath $previousLocation.Path
    $env:Path = $previousPath
  }
}

function ConvertTo-IntList {
  param(
    $Values,
    [int[]]$DefaultValues
  )

  $result = @()
  if ($Values) {
    foreach ($value in $Values) {
      if ($null -eq $value) { continue }
      if ($value -is [array]) {
        foreach ($inner in $value) {
          if ($null -ne $inner) { $result += [int]$inner }
        }
      } else {
        $result += [int]$value
      }
    }
  }

  if ($result.Count -eq 0) {
    $result = @()
    foreach ($default in $DefaultValues) {
      $result += [int]$default
    }
  }

  return $result
}

function Get-DefaultIconEditorDevModeTargets {
  param([string]$Operation)

  $normalized = if ($Operation) { $Operation.ToLowerInvariant() } else { 'compare' }
  switch ($normalized) {
    'buildpackage' {
      return [pscustomobject]@{
        Versions = @(2023)
        Bitness  = @(32, 64)
      }
    }
    default {
      return [pscustomobject]@{
        Versions = @(2025)
        Bitness  = @(64)
      }
    }
  }
}

function Get-IconEditorDevModePolicyPath {
  param([string]$RepoRoot)

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  if ($env:ICON_EDITOR_DEV_MODE_POLICY_PATH) {
    return (Resolve-Path -LiteralPath $env:ICON_EDITOR_DEV_MODE_POLICY_PATH).Path
  }

  return (Join-Path $RepoRoot 'configs' 'icon-editor' 'dev-mode-targets.json')
}

function Get-IconEditorDevModePolicy {
  param(
    [string]$RepoRoot,
    [switch]$ThrowIfMissing
  )

  $policyPath = Get-IconEditorDevModePolicyPath -RepoRoot $RepoRoot
  if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    if ($ThrowIfMissing.IsPresent) {
      throw "Icon editor dev-mode policy not found at '$policyPath'."
    }
    return $null
  }

  try {
    $policyContent = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8
    $policy = $policyContent | ConvertFrom-Json -AsHashtable -Depth 5
  } catch {
    throw "Failed to parse icon editor dev-mode policy '$policyPath': $($_.Exception.Message)"
  }

  if (-not ($policy -and $policy.ContainsKey('operations'))) {
    if ($ThrowIfMissing.IsPresent) {
      throw "Icon editor dev-mode policy at '$policyPath' is missing the 'operations' node."
    }
    return $null
  }

  return [pscustomobject]@{
    Path       = (Resolve-Path -LiteralPath $policyPath).Path
    Schema     = $policy['schema']
    Operations = $policy['operations']
  }
}

function Get-IconEditorDevModePolicyEntry {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [string]$RepoRoot
  )

  $policy = Get-IconEditorDevModePolicy -RepoRoot $RepoRoot -ThrowIfMissing
  $operations = $policy.Operations
  if (-not $operations) {
    throw "Icon editor dev-mode policy at '$($policy.Path)' does not define any operations."
  }

  $entry = $null
  if ($operations.ContainsKey($Operation)) {
    $entry = $operations[$Operation]
    $operationKey = $Operation
  } else {
    foreach ($key in $operations.Keys) {
      if ($key -and ($key.ToString().ToLowerInvariant() -eq $Operation.ToLowerInvariant())) {
        $entry = $operations[$key]
        $operationKey = $key
        break
      }
    }
  }

  if (-not $entry) {
    throw "Operation '$Operation' is not defined in icon editor dev-mode policy '$($policy.Path)'."
  }

  $versions = @()
  if ($entry.versions) {
    foreach ($value in $entry.versions) {
      if ($null -ne $value) { $versions += [int]$value }
    }
  }

  $bitness = @()
  if ($entry.bitness) {
    foreach ($value in $entry.bitness) {
      if ($null -ne $value) { $bitness += [int]$value }
    }
  }

  return [pscustomobject]@{
    Operation = $operationKey
    Versions  = $versions
    Bitness   = $bitness
    Path      = $policy.Path
  }
}

function Enable-IconEditorDevelopmentMode {
  param(
    [string]$RepoRoot,
    [string]$IconEditorRoot,
    [int[]]$Versions,
    [int[]]$Bitness,
    [string]$Operation = 'Compare'
  )

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  if (-not $IconEditorRoot) {
    $IconEditorRoot = Resolve-IconEditorRoot -RepoRoot $RepoRoot
  } else {
    $IconEditorRoot = (Resolve-Path -LiteralPath $IconEditorRoot).Path
  }

  $actionsRoot = Join-Path $IconEditorRoot '.github' 'actions'
  $addTokenScript = Join-Path $actionsRoot 'add-token-to-labview' 'AddTokenToLabVIEW.ps1'
  $prepareScript  = Join-Path $actionsRoot 'prepare-labview-source' 'Prepare_LabVIEW_source.ps1'
  $closeScript    = Join-Path $actionsRoot 'close-labview' 'Close_LabVIEW.ps1'

  foreach ($required in @($addTokenScript, $prepareScript, $closeScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Icon editor dev-mode helper '$required' was not found."
    }
  }

  $targetsOverride = $null
  if (-not $PSBoundParameters.ContainsKey('Versions') -or -not $PSBoundParameters.ContainsKey('Bitness')) {
    try {
      $targetsOverride = Get-IconEditorDevModePolicyEntry -RepoRoot $RepoRoot -Operation $Operation
    } catch {
      $targetsOverride = $null
      if (-not $PSBoundParameters.ContainsKey('Versions') -and -not $PSBoundParameters.ContainsKey('Bitness')) {
        throw
      }
    }
  }

  $defaultTargets = Get-DefaultIconEditorDevModeTargets -Operation $Operation
  [array]$overrideVersions = @()
  [array]$overrideBitness  = @()
  if ($targetsOverride) {
    $overrideVersions = @($targetsOverride.Versions)
    $overrideBitness  = @($targetsOverride.Bitness)
  }
  [array]$effectiveVersions = if ($overrideVersions.Count -gt 0) { $overrideVersions } else { @($defaultTargets.Versions) }
  [array]$effectiveBitness  = if ($overrideBitness.Count -gt 0)  { $overrideBitness }  else { @($defaultTargets.Bitness) }

  [array]$versionList = ConvertTo-IntList -Values $Versions -DefaultValues $effectiveVersions
  [array]$bitnessList = ConvertTo-IntList -Values $Bitness -DefaultValues $effectiveBitness

  if ($versionList.Count -eq 0 -or $bitnessList.Count -eq 0) {
    throw "LabVIEW version/bitness selection resolved to an empty set for operation '$Operation'."
  }

  $pluginsPath = Join-Path $IconEditorRoot 'resource' 'plugins'
  if (Test-Path -LiteralPath $pluginsPath -PathType Container) {
    Get-ChildItem -LiteralPath $pluginsPath -Filter '*.lvlibp' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  }

  foreach ($versionValue in $versionList) {
    $versionText = [string]$versionValue
    foreach ($bitnessValue in $bitnessList) {
      $bitnessText = [string]$bitnessValue
      Invoke-IconEditorDevModeScript `
        -ScriptPath $addTokenScript `
        -ArgumentList @(
          '-MinimumSupportedLVVersion', $versionText,
          '-SupportedBitness',          $bitnessText,
          '-RelativePath',            $IconEditorRoot
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot

      Invoke-IconEditorDevModeScript `
        -ScriptPath $prepareScript `
        -ArgumentList @(
          '-MinimumSupportedLVVersion', $versionText,
          '-SupportedBitness',          $bitnessText,
          '-RelativePath',            $IconEditorRoot,
          '-LabVIEW_Project',         'lv_icon_editor',
          '-Build_Spec',              'Editor Packed Library'
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot

      Invoke-IconEditorDevModeScript `
        -ScriptPath $closeScript `
        -ArgumentList @(
          '-MinimumSupportedLVVersion', $versionText,
          '-SupportedBitness',          $bitnessText
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot
    }
  }

  return Set-IconEditorDevModeState -RepoRoot $RepoRoot -Active $true -Source ("Enable-IconEditorDevelopmentMode:{0}" -f $Operation)
}

function Disable-IconEditorDevelopmentMode {
  param(
    [string]$RepoRoot,
    [string]$IconEditorRoot,
    [int[]]$Versions,
    [int[]]$Bitness,
    [string]$Operation = 'Compare'
  )

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  if (-not $IconEditorRoot) {
    $IconEditorRoot = Resolve-IconEditorRoot -RepoRoot $RepoRoot
  } else {
    $IconEditorRoot = (Resolve-Path -LiteralPath $IconEditorRoot).Path
  }

  $actionsRoot = Join-Path $IconEditorRoot '.github' 'actions'
  $restoreScript = Join-Path $actionsRoot 'restore-setup-lv-source' 'RestoreSetupLVSource.ps1'
  $closeScript   = Join-Path $actionsRoot 'close-labview' 'Close_LabVIEW.ps1'

  foreach ($required in @($restoreScript, $closeScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Icon editor dev-mode helper '$required' was not found."
    }
  }

  $targetsOverride = $null
  if (-not $PSBoundParameters.ContainsKey('Versions') -or -not $PSBoundParameters.ContainsKey('Bitness')) {
    try {
      $targetsOverride = Get-IconEditorDevModePolicyEntry -RepoRoot $RepoRoot -Operation $Operation
    } catch {
      $targetsOverride = $null
    }
  }

  $defaultTargets = Get-DefaultIconEditorDevModeTargets -Operation $Operation
  [array]$overrideVersions = @()
  [array]$overrideBitness  = @()
  if ($targetsOverride) {
    $overrideVersions = @($targetsOverride.Versions)
    $overrideBitness  = @($targetsOverride.Bitness)
  }
  [array]$effectiveVersions = if ($overrideVersions.Count -gt 0) { $overrideVersions } else { @($defaultTargets.Versions) }
  [array]$effectiveBitness  = if ($overrideBitness.Count -gt 0)  { $overrideBitness }  else { @($defaultTargets.Bitness) }

  [array]$versionsList = ConvertTo-IntList -Values $Versions -DefaultValues $effectiveVersions
  [array]$bitnessList  = ConvertTo-IntList -Values $Bitness -DefaultValues $effectiveBitness

  if ($versionsList.Count -eq 0 -or $bitnessList.Count -eq 0) {
    throw "LabVIEW version/bitness selection resolved to an empty set for operation '$Operation'."
  }

  foreach ($versionValue in $versionsList) {
    $versionText = [string]$versionValue
    foreach ($bitnessValue in $bitnessList) {
      $bitnessText = [string]$bitnessValue
      Invoke-IconEditorDevModeScript `
        -ScriptPath $restoreScript `
        -ArgumentList @(
          '-MinimumSupportedLVVersion', $versionText,
          '-SupportedBitness',          $bitnessText,
          '-RelativePath',            $IconEditorRoot,
          '-LabVIEW_Project',         'lv_icon_editor',
          '-Build_Spec',              'Editor Packed Library'
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot

      Invoke-IconEditorDevModeScript `
        -ScriptPath $closeScript `
        -ArgumentList @(
          '-MinimumSupportedLVVersion', $versionText,
          '-SupportedBitness',          $bitnessText
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot
    }
  }

  return Set-IconEditorDevModeState -RepoRoot $RepoRoot -Active $false -Source ("Disable-IconEditorDevelopmentMode:{0}" -f $Operation)
}

function Get-IconEditorDevModeLabVIEWTargets {
  param(
    [string]$RepoRoot,
    [string]$IconEditorRoot,
    [int[]]$Versions = @(2023),
    [int[]]$Bitness = @(32, 64)
  )

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  if (-not $IconEditorRoot) {
    $IconEditorRoot = Resolve-IconEditorRoot -RepoRoot $RepoRoot
  } else {
    $IconEditorRoot = (Resolve-Path -LiteralPath $IconEditorRoot).Path
  }

  Import-Module (Join-Path $RepoRoot 'tools' 'VendorTools.psm1') -Force

  $versionList = ConvertTo-IntList -Values $Versions -DefaultValues @(2023)
  $bitnessList = ConvertTo-IntList -Values $Bitness -DefaultValues @(32,64)

  $targets = New-Object System.Collections.Generic.List[object]
  foreach ($version in $versionList) {
    foreach ($bit in $bitnessList) {
      $exePath = Find-LabVIEWVersionExePath -Version $version -Bitness $bit
      $iniPath = $null
      $present = $false
      if ($exePath) {
        $present = $true
        $iniPath = Get-LabVIEWIniPath -LabVIEWExePath $exePath
      }
      $targets.Add([pscustomobject]@{
        Version = $version
        Bitness = $bit
        LabVIEWExePath = $exePath
        LabVIEWIniPath = $iniPath
        Present = [bool]$present
        IconEditorRoot = $IconEditorRoot
      }) | Out-Null
    }
  }

  return $targets.ToArray()
}

function Test-IconEditorDevelopmentMode {
  param(
    [string]$RepoRoot,
    [string]$IconEditorRoot,
    [int[]]$Versions = @(2023),
    [int[]]$Bitness = @(32, 64)
  )

  if (-not $RepoRoot) {
    $RepoRoot = Resolve-IconEditorRepoRoot
  } else {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  if (-not $IconEditorRoot) {
    $IconEditorRoot = Resolve-IconEditorRoot -RepoRoot $RepoRoot
  } else {
    $IconEditorRoot = (Resolve-Path -LiteralPath $IconEditorRoot).Path
  }

  $iconEditorRootLower = $IconEditorRoot.ToLowerInvariant().TrimEnd('\')
  $targets = Get-IconEditorDevModeLabVIEWTargets -RepoRoot $RepoRoot -IconEditorRoot $IconEditorRoot -Versions $Versions -Bitness $Bitness
  $results = New-Object System.Collections.Generic.List[object]

  foreach ($target in $targets) {
    $tokenValue = $null
    $containsIconEditor = $false
    if ($target.Present -and $target.LabVIEWIniPath -and (Test-Path -LiteralPath $target.LabVIEWIniPath -PathType Leaf)) {
      try {
        $tokenValue = Get-LabVIEWIniValue -Key 'LocalHost.LibraryPaths' -LabVIEWExePath $target.LabVIEWExePath -LabVIEWIniPath $target.LabVIEWIniPath
      } catch {
        $tokenValue = $null
      }
      if ($tokenValue) {
        $normalizedValue = ($tokenValue -replace '"', '').Split(';') | ForEach-Object {
          $_.Trim().TrimEnd('\').ToLowerInvariant()
        }
        foreach ($entry in $normalizedValue) {
          if ($entry -eq '') { continue }
          if ($entry -eq $iconEditorRootLower -or $entry.StartsWith($iconEditorRootLower)) {
            $containsIconEditor = $true
            break
          }
        }
      }
    }

    $results.Add([pscustomobject]@{
      Version = $target.Version
      Bitness = $target.Bitness
      LabVIEWExePath = $target.LabVIEWExePath
      LabVIEWIniPath = $target.LabVIEWIniPath
      Present = $target.Present
      TokenValue = $tokenValue
      ContainsIconEditorPath = $containsIconEditor
    }) | Out-Null
  }

  $presentEntries = $results | Where-Object { $_.Present }
  $active = $null
  if ($presentEntries.Count -gt 0) {
    $active = $presentEntries | ForEach-Object { $_.ContainsIconEditorPath } | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
    $active = ($active -eq $presentEntries.Count)
  }

  return [pscustomobject]@{
    RepoRoot = $RepoRoot
    IconEditorRoot = $IconEditorRoot
    Active = $active
    Entries = $results
  }
}

Export-ModuleMember -Function `
  Resolve-IconEditorRepoRoot, `
  Resolve-IconEditorRoot, `
  Get-IconEditorDevModeStatePath, `
  Get-IconEditorDevModeState, `
  Set-IconEditorDevModeState, `
  Invoke-IconEditorDevModeScript, `
  Enable-IconEditorDevelopmentMode, `
  Disable-IconEditorDevelopmentMode, `
  Get-IconEditorDevModePolicyPath, `
  Get-IconEditorDevModePolicy, `
  Get-IconEditorDevModePolicyEntry, `
  Get-IconEditorDevModeLabVIEWTargets, `
  Test-IconEditorDevelopmentMode
