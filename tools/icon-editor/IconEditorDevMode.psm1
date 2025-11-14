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

function Invoke-IconEditorRogueCheck {
  param(
    [string]$RepoRoot,
    [string]$Stage,
    [switch]$FailOnRogue,
    [switch]$AutoClose
  )

  try {
    if (-not $RepoRoot) {
      $RepoRoot = Resolve-IconEditorRepoRoot
    } else {
      $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    }
  } catch {
    $RepoRoot = Resolve-IconEditorRepoRoot
  }

  $detectScript = Join-Path $RepoRoot 'tools' 'Detect-RogueLV.ps1'
  if (-not (Test-Path -LiteralPath $detectScript -PathType Leaf)) {
    return $null
  }

  $resultsDir = Join-Path $RepoRoot 'tests' 'results'
  if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
    try { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null } catch {}
  }

  $outputDir = Join-Path $resultsDir '_agent' 'icon-editor' 'rogue-lv'
  if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    try { New-Item -ItemType Directory -Force -Path $outputDir | Out-Null } catch {}
  }

  $safeStage = if ($Stage) { ($Stage -replace '[^a-zA-Z0-9_-]','-') } else { 'icon-editor' }
  if ([string]::IsNullOrWhiteSpace($safeStage)) { $safeStage = 'icon-editor' }
  $timestamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
  $outputPath = Join-Path $outputDir ("rogue-lv-{0}-{1}.json" -f $safeStage.ToLowerInvariant(), $timestamp)

  $pwshExe = 'pwsh'
  try {
    $cmd = Get-Command -Name 'pwsh' -ErrorAction Stop
    if ($cmd -and $cmd.Source) {
      $pwshExe = $cmd.Source
    } elseif ($cmd -and $cmd.Path) {
      $pwshExe = $cmd.Path
    }
  } catch {}

  $args = @(
    '-NoLogo',
    '-NoProfile',
    '-File', $detectScript,
    '-ResultsDir', $resultsDir,
    '-OutputPath', $outputPath,
    '-LookBackSeconds', '300',
    '-RetryCount', '2',
    '-RetryDelaySeconds', '5'
  )
  if ($env:GITHUB_STEP_SUMMARY) {
    $args += '-AppendToStepSummary'
  }
  if ($FailOnRogue) {
    $args += '-FailOnRogue'
  }

  $exitCode = 0
  try {
    & $pwshExe @args | Out-Null
    $exitCode = $LASTEXITCODE
  } catch {
    Write-Warning ("Detect-RogueLV failed during stage '{0}': {1}" -f $Stage, $_.Exception.Message)
    return $null
  }

  if ($exitCode -ne 0 -and $AutoClose) {
    $closeScript = Join-Path $RepoRoot 'tools' 'Close-LabVIEW.ps1'
    if (Test-Path -LiteralPath $closeScript -PathType Leaf) {
      try {
        & $pwshExe -NoLogo -NoProfile -File $closeScript | Out-Null
      } catch {
        Write-Warning ("Automatic Close-LabVIEW attempt failed: {0}" -f $_.Exception.Message)
      }
    }
    try {
      & $pwshExe @args | Out-Null
      $exitCode = $LASTEXITCODE
    } catch {
      Write-Warning ("Detect-RogueLV retry failed during stage '{0}': {1}" -f $Stage, $_.Exception.Message)
    }
  }

  if ($exitCode -ne 0) {
    $message = "Rogue LabVIEW/LVCompare processes detected (stage '{0}'). See {1} for details." -f $Stage, $outputPath
    if ($FailOnRogue) {
      throw $message
    } else {
      Write-Warning $message
    }
  }

  return [pscustomobject]@{
    Stage    = $Stage
    ExitCode = $exitCode
    Path     = $outputPath
  }
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
  $scriptDirectory = Split-Path -Parent $ScriptPath
  $previousLocation = Get-Location

  $pwshCmd = Get-Command pwsh -ErrorAction Stop
  $args = if ($ArgumentList -and $ArgumentList.Count -gt 0) { $ArgumentList } else { @('-IconEditorRoot', $IconEditorRoot) }

  Set-Location -LiteralPath $scriptDirectory
  try {
    $scriptOutput = @()
    & $pwshCmd.Source -NoLogo -NoProfile -File $ScriptPath @args 2>&1 |
      Tee-Object -Variable scriptOutput | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      $capturedText = ($scriptOutput | Out-String).Trim()
      $message = "Dev-mode script '$ScriptPath' exited with code $exitCode."
      if (-not [string]::IsNullOrWhiteSpace($capturedText)) {
        $message += [Environment]::NewLine + $capturedText
      }
      throw $message
    }
  }
  finally {
    Set-Location -LiteralPath $previousLocation.Path
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

  $preStage = if ($Operation) { "disable-{0}-pre" -f $Operation } else { 'disable-devmode-pre' }
  Invoke-IconEditorRogueCheck -RepoRoot $RepoRoot -Stage $preStage -FailOnRogue -AutoClose | Out-Null

  $actionsRoot = Join-Path $IconEditorRoot '.github' 'actions'
  $addTokenScript = Join-Path $actionsRoot 'add-token-to-labview' 'AddTokenToLabVIEW.ps1'
  $prepareScript  = Join-Path $actionsRoot 'prepare-labview-source' 'Prepare_LabVIEW_source.ps1'

  foreach ($required in @($addTokenScript, $prepareScript)) {
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
          '-RelativePath',              $IconEditorRoot
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot

      Invoke-IconEditorDevModeScript `
        -ScriptPath $prepareScript `
        -ArgumentList @(
          '-MinimumSupportedLVVersion', $versionText,
          '-SupportedBitness',          $bitnessText,
          '-RelativePath',              $IconEditorRoot,
          '-LabVIEW_Project',         'lv_icon_editor',
          '-Build_Spec',              'Editor Packed Library'
        ) `
        -RepoRoot $RepoRoot `
        -IconEditorRoot $IconEditorRoot

      # Keep LabVIEW running after preparing source; closing is handled elsewhere when needed.
    }
  }

  $verification = Assert-IconEditorDevModeTokenState -RepoRoot $RepoRoot -IconEditorRoot $IconEditorRoot -Versions $versionList -Bitness $bitnessList -ExpectedActive $true
  $state = Set-IconEditorDevModeState -RepoRoot $RepoRoot -Active $true -Source ("Enable-IconEditorDevelopmentMode:{0}" -f $Operation)
  if ($verification) {
    $state | Add-Member -NotePropertyName Verification -NotePropertyValue $verification -Force
  }
  Close-IconEditorLabVIEW -RepoRoot $RepoRoot -IconEditorRoot $IconEditorRoot -Versions $versionList -Bitness $bitnessList
  $postStage = if ($Operation) { "devmode-{0}-post" -f $Operation } else { 'devmode-post' }
  Invoke-IconEditorRogueCheck -RepoRoot $RepoRoot -Stage $postStage -AutoClose | Out-Null
  return $state
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
  $resetHelper   = Join-Path $RepoRoot 'tools' 'icon-editor' 'Reset-IconEditorWorkspace.ps1'

  foreach ($required in @($restoreScript, $closeScript, $resetHelper)) {
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

  if ($versionsList.Count -eq 0) {
    $versionsList = @($effectiveVersions | ForEach-Object { [int]$_ })
  }
  if ($bitnessList.Count -eq 0) {
    $bitnessList = @($effectiveBitness | ForEach-Object { [int]$_ })
  }

  if ($versionsList.Count -eq 0 -or $bitnessList.Count -eq 0) {
    throw "LabVIEW version/bitness selection resolved to an empty set for operation '$Operation'."
  }

  try {
    & $resetHelper `
      -RepoRoot $RepoRoot `
      -IconEditorRoot $IconEditorRoot `
      -Versions $versionsList `
      -Bitness $bitnessList | Out-Null
  } catch {
    throw "Reset-IconEditorWorkspace.ps1 failed: $($_.Exception.Message)"
  }

  $verification = Assert-IconEditorDevModeTokenState -RepoRoot $RepoRoot -IconEditorRoot $IconEditorRoot -Versions $versionsList -Bitness $bitnessList -ExpectedActive $false
  $state = Set-IconEditorDevModeState -RepoRoot $RepoRoot -Active $false -Source ("Disable-IconEditorDevelopmentMode:{0}" -f $Operation)
  if ($verification) {
    $state | Add-Member -NotePropertyName Verification -NotePropertyValue $verification -Force
  }
  Close-IconEditorLabVIEW -RepoRoot $RepoRoot -IconEditorRoot $IconEditorRoot -Versions $versionsList -Bitness $bitnessList
  $postStage = if ($Operation) { "disable-{0}-post" -f $Operation } else { 'disable-devmode-post' }
  Invoke-IconEditorRogueCheck -RepoRoot $RepoRoot -Stage $postStage -AutoClose | Out-Null
  return $state
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

function Assert-IconEditorDevModeTokenState {
  param(
    [string]$RepoRoot,
    [string]$IconEditorRoot,
    [int[]]$Versions,
    [int[]]$Bitness,
    [bool]$ExpectedActive
  )

  $verification = Test-IconEditorDevelopmentMode -RepoRoot $RepoRoot -IconEditorRoot $IconEditorRoot -Versions $Versions -Bitness $Bitness
  if (-not $verification) { return $null }

  $presentEntries = @($verification.Entries | Where-Object { $_.Present -and $_.LabVIEWIniPath })
  if (-not $presentEntries -or $presentEntries.Count -eq 0) {
    Write-Verbose "Icon editor dev-mode verification: no LabVIEW targets present; skipping token check."
    return $verification
  }

  $violations = if ($ExpectedActive) {
    @($presentEntries | Where-Object { -not $_.ContainsIconEditorPath })
  } else {
    @($presentEntries | Where-Object { $_.ContainsIconEditorPath })
  }

  if ($violations -and $violations.Count -gt 0) {
    $expectation = if ($ExpectedActive) { 'include' } else { 'exclude' }
    $details = $violations | ForEach-Object {
      $iniPath = if ($_.LabVIEWIniPath) { $_.LabVIEWIniPath } else { '[ini path unavailable]' }
      $status = if ($_.ContainsIconEditorPath) { 'contains icon-editor path' } else { 'missing icon-editor path' }
      "LabVIEW {0} ({1}-bit) - {2} (ini: {3})" -f $_.Version, $_.Bitness, $status, $iniPath
    }
    $joined = [string]::Join('; ', $details)
    throw "Icon editor dev-mode verification failed: expected LabVIEW to $expectation the icon-editor path. Violations: $joined"
  }

  return $verification
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

  $presentEntries = @($results | Where-Object { $_.Present })
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

function Close-IconEditorLabVIEW {
  param(
    [string]$RepoRoot,
    [string]$IconEditorRoot,
    [int[]]$Versions,
    [int[]]$Bitness,
    [int]$WaitTimeoutSeconds = 30
  )

  $skipWait = $false
  $skipEnv = $env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT
  if ($skipEnv) {
    $value = $skipEnv.ToString().ToLowerInvariant()
    if ($value -in @('1','true','yes','on')) {
      $skipWait = $true
    }
  }

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
  $closeScript = Join-Path $actionsRoot 'close-labview' 'Close_LabVIEW.ps1'
  if (-not (Test-Path -LiteralPath $closeScript -PathType Leaf)) {
    Write-Verbose "Close-IconEditorLabVIEW: close script not found at '$closeScript'; skipping graceful shutdown."
    return
  }

  Import-Module (Join-Path $RepoRoot 'tools' 'VendorTools.psm1') -Force

  $rawVersions = ConvertTo-IntList -Values $Versions -DefaultValues @(2023)
  $rawBitness  = ConvertTo-IntList -Values $Bitness -DefaultValues @(32, 64)
  $versionList = if ($rawVersions) { @($rawVersions) } else { @() }
  $bitnessList = if ($rawBitness) { @($rawBitness) } else { @() }
  $expectedExePaths = New-Object System.Collections.Generic.List[string]

  foreach ($version in $versionList) {
    foreach ($bit in $bitnessList) {
      $attemptArgs = @(
        '-MinimumSupportedLVVersion', [string]$version,
        '-SupportedBitness',          [string]$bit
      )

      $closeSucceeded = $false
      for ($attempt = 1; $attempt -le 2 -and -not $closeSucceeded; $attempt++) {
        try {
          Invoke-IconEditorDevModeScript `
            -ScriptPath $closeScript `
            -ArgumentList $attemptArgs `
            -RepoRoot $RepoRoot `
            -IconEditorRoot $IconEditorRoot
          $closeSucceeded = $true
        } catch {
          $message = $_.Exception.Message
          $transient = $message -match 'Timed out waiting for app to connect to g-cli' -or $message -match 'Failed to close LabVIEW with exit code 1'
          if ($transient -and $attempt -lt 2) {
            Write-Warning ("Close-IconEditorLabVIEW: retrying after g-cli timeout when closing LabVIEW {0} ({1}-bit)." -f $version, $bit)
            Start-Sleep -Seconds 2
            continue
          }
          if ($transient) {
            Write-Warning ("Close-IconEditorLabVIEW: ignoring repeated g-cli timeout when closing LabVIEW {0} ({1}-bit): {2}" -f $version, $bit, $message)
            $closeSucceeded = $true
          } else {
            throw
          }
        }
      }

      $exePath = Find-LabVIEWVersionExePath -Version $version -Bitness $bit
      if ($exePath) {
        $resolvedExe = $null
        try {
          $resolvedExe = (Resolve-Path -LiteralPath $exePath).Path.ToLowerInvariant()
        } catch {
          $resolvedExe = $exePath.ToLowerInvariant()
        }
        if ($resolvedExe -and -not $expectedExePaths.Contains($resolvedExe)) {
          [void]$expectedExePaths.Add($resolvedExe)
        }
      }
    }
  }

  $exeArray = if ($expectedExePaths.Count -gt 0) { $expectedExePaths.ToArray() } else { @() }

  if ($skipWait) {
    Write-Verbose "Close-IconEditorLabVIEW: skipping wait for LabVIEW exit (ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT=$skipEnv)."
    return
  }

  if (-not (Wait-LabVIEWProcessExit -ExeCandidates $exeArray -TimeoutSeconds $WaitTimeoutSeconds)) {
    Write-Warning "Initial wait for LabVIEW exit timed out; attempting forced termination."
    foreach ($candidate in $exeArray) {
      if (-not $candidate) { continue }
      try {
        Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Where-Object {
          $path = $null
          try { $path = $_.Path } catch { $path = $null }
          if (-not $path) { return $false }
          $path.ToLowerInvariant() -eq $candidate
        } | Stop-Process -Force -ErrorAction SilentlyContinue
      } catch {
        Write-Warning ("Failed to force-close LabVIEW process for path '{0}': {1}" -f $candidate, $_.Exception.Message)
      }
    }

  if (-not (Wait-LabVIEWProcessExit -ExeCandidates $exeArray -TimeoutSeconds 10)) {
    throw "Timed out waiting for LabVIEW to exit after close sequence."
  }

  Invoke-IconEditorRogueCheck -RepoRoot $RepoRoot -Stage 'close-labview' -AutoClose | Out-Null
}
}

function Wait-LabVIEWProcessExit {
  param(
    [string[]]$ExeCandidates,
    [int]$TimeoutSeconds = 30
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $normalizedCandidates = @()
  if ($ExeCandidates) {
    $normalizedCandidates = $ExeCandidates | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }
  }

  while ($true) {
    $running = @(Get-Process LabVIEW -ErrorAction SilentlyContinue)
    if (-not $running -or $running.Count -eq 0) {
      return $true
    }

    if ($normalizedCandidates.Length -gt 0) {
      $matching = @()
      foreach ($proc in $running) {
        $procPath = $null
        try {
          $procPath = $proc.Path
        } catch {
          $procPath = $null
        }
        if (-not $procPath) {
          $matching += $proc
          continue
        }
        $procNormalized = $procPath.ToLowerInvariant()
        if ($normalizedCandidates -contains $procNormalized) {
          $matching += $proc
        }
      }
      if ($matching.Count -eq 0) {
        return $true
      }
    } else {
      if ($running.Count -eq 0) {
        return $true
      }
    }

    if ((Get-Date) -ge $deadline) {
      return $false
    }

    Start-Sleep -Milliseconds 500
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
  Assert-IconEditorDevModeTokenState, `
  Test-IconEditorDevelopmentMode
