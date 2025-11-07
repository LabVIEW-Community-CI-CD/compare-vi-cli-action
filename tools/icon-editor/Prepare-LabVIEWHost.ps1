#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$FixturePath,
  [object[]]$Versions = @(2021),
  [object[]]$Bitness = @(32, 64),
  [string]$StageName,
  [string]$WorkspaceRoot,
  [string]$IconEditorRoot,
  [string]$Operation = 'MissingInProject',
  [switch]$SkipStage,
  [switch]$SkipStageValidate,
  [switch]$SkipDevMode,
  [switch]$SkipClose,
  [switch]$SkipReset,
  [switch]$SkipRogueDetection,
  [switch]$SkipPostRogueDetection,
  [switch]$DryRun,
  [int]$RogueLookBackSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HostPrepClosureEvents = @()
$script:HostPrepCloseScriptPath = $null
$script:HostPrepDryRun = $false

function Get-LabVIEWProcesses {
  try {
    return @(Get-Process -Name 'LabVIEW' -ErrorAction Stop)
  } catch {
    return @()
  }
}

function Ensure-LabVIEWClosed {
  param(
    [Parameter(Mandatory)][string]$Context,
    [Parameter(Mandatory)][string]$CloseScriptPath,
    [int]$MaxAttempts = 3,
    [int]$WaitSeconds = 5
  )

  $event = [ordered]@{
    context         = $Context
    at              = (Get-Date).ToString('o')
    initialPidCount = (Get-LabVIEWProcesses).Count
    attempts        = 0
    forcedTermination = $false
    terminatedPids  = @()
    finalPidCount   = $null
  }

  if ($event.initialPidCount -eq 0) {
    $event.finalPidCount = 0
    return [pscustomobject]$event
  }

  if (-not (Test-Path -LiteralPath $CloseScriptPath -PathType Leaf)) {
    $event['note'] = 'close-script-missing'
    return [pscustomobject]$event
  }

  $attemptLimit = [Math]::Max(1, [Math]::Abs([int]$MaxAttempts))
  $waitSeconds = [Math]::Max(1, [Math]::Abs([int]$WaitSeconds))

  for ($i = 1; $i -le $attemptLimit; $i++) {
    $event.attempts = $i
    try {
      & $CloseScriptPath | Out-Null
    } catch {
      Write-Warning ("[prep] Close-LabVIEW helper failed during context '{0}': {1}" -f $Context, $_.Exception.Message)
    }
    Start-Sleep -Seconds $waitSeconds
    $live = Get-LabVIEWProcesses
    if ($live.Count -eq 0) {
      $event.finalPidCount = 0
      return [pscustomobject]$event
    }
  }

  $remaining = Get-LabVIEWProcesses
  if ($remaining.Count -eq 0) {
    $event.finalPidCount = 0
    return [pscustomobject]$event
  }

  $event.forcedTermination = $true
  $event.terminatedPids = @($remaining | ForEach-Object { $_.Id })
  Write-Warning ("[prep] Forcing LabVIEW shutdown ({0}) during context '{1}'." -f ($event.terminatedPids -join ','), $Context)
  foreach ($proc in $remaining) {
    try {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Warning ("[prep] Stop-Process failed for PID {0}: {1}" -f $proc.Id, $_.Exception.Message)
    }
  }
  Start-Sleep -Milliseconds 250
  $finalCheck = Get-LabVIEWProcesses
  $event.finalPidCount = $finalCheck.Count
  if ($finalCheck.Count -gt 0) {
    throw "Failed to terminate LabVIEW processes ({0}) during context '{1}'." -f ($finalCheck.Id -join ','), $Context
  }
  return [pscustomobject]$event
}

function Invoke-ClosureCheck {
  param(
    [Parameter(Mandatory)][string]$Context,
    [int]$WaitSeconds = 5
  )

  if ($script:HostPrepDryRun) { return }
  $closePath = $script:HostPrepCloseScriptPath
  if (-not $closePath) { return }

  $event = $null
  try {
    $event = Ensure-LabVIEWClosed -Context $Context -CloseScriptPath $closePath -WaitSeconds $WaitSeconds
  } catch {
    throw
  } finally {
    if ($event) {
      $script:HostPrepClosureEvents += $event
    }
  }
}

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    $root = git -C $StartPath rev-parse --show-toplevel 2>$null
    if ($root) {
      return (Resolve-Path -LiteralPath $root.Trim()).Path
    }
  } catch {}
  return (Resolve-Path -LiteralPath $StartPath).Path
}

function Resolve-OptionalPath {
  param(
    [string]$Path,
    [string]$BasePath
  )
  if (-not $Path) { return $null }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    try {
      return (Resolve-Path -LiteralPath $Path).Path
    } catch {
      return [System.IO.Path]::GetFullPath($Path)
    }
  }
  $base = if ($BasePath) { $BasePath } else { (Get-Location).Path }
  $candidate = Join-Path $base $Path
  try {
    return (Resolve-Path -LiteralPath $candidate).Path
  } catch {
    return [System.IO.Path]::GetFullPath($candidate)
  }
}

function Convert-ToIntList {
  param(
    [object[]]$Values,
    [int[]]$Defaults,
    [string]$Name,
    [ValidateScript({ $true })][scriptblock]$Validator
  )

  $result = @()
  $source = if ($Values -and $Values.Count -gt 0) { $Values } else { $Defaults }
  foreach ($entry in $source) {
    if ($null -eq $entry) { continue }
    if ($entry -is [System.Array]) {
      $result += Convert-ToIntList -Values $entry -Defaults @() -Name $Name -Validator $Validator
      continue
    }
    if ($entry -is [string]) {
      $normalized = $entry.Trim()
      if ($normalized -match '[,;\s]') {
        $parts = $normalized -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($parts.Count -gt 1) {
          $result += Convert-ToIntList -Values $parts -Defaults @() -Name $Name -Validator $Validator
          continue
        } else {
          $entry = $normalized
        }
      }
    }
    try {
      $value = [int]$entry
      if ($Validator -and -not (& $Validator $value)) {
        throw "Value '$value' did not pass validation for $Name."
      }
      $result += $value
    } catch {
      throw "Unable to parse $Name entry '$entry': $($_.Exception.Message)"
    }
  }
  $result = @($result | Sort-Object -Unique)
  if ($result.Count -eq 0) {
    throw "No valid values supplied for $Name."
  }
  return $result
}

function Invoke-RogueDetection {
  param(
    [string]$StageLabel,
    [string]$ScriptPath,
    [string]$ResultsDir,
    [int]$LookBackSeconds,
    [switch]$Skip
  )

  if ($Skip) { return }
  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Write-Warning "Detect-RogueLV.ps1 not found at '$ScriptPath'; skipping rogue scan."
    return
  }

  $outputDir = Join-Path $ResultsDir '_agent' 'icon-editor' 'rogue-lv'
  if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputDir -Force)
  }
  $outputPath = Join-Path $outputDir ("rogue-{0}-{1}.json" -f $StageLabel.Replace(' ', '-'), (Get-Date -Format 'yyyyMMddTHHmmssfff'))

  Write-Host ("[prep] Running rogue LV detection ({0})..." -f $StageLabel)
  & $ScriptPath `
    -ResultsDir $ResultsDir `
    -LookBackSeconds $LookBackSeconds `
    -FailOnRogue `
    -OutputPath $outputPath `
    -AppendToStepSummary:$false |
    Out-Null
}

$repoRoot = Resolve-RepoRoot
$fixtureResolved = Resolve-OptionalPath -Path $FixturePath -BasePath $repoRoot
if (-not $fixtureResolved -or -not (Test-Path -LiteralPath $fixtureResolved -PathType Leaf)) {
  throw "Fixture VIP not found at '$FixturePath'."
}

$iconEditorRootResolved = if ($IconEditorRoot) {
  Resolve-OptionalPath -Path $IconEditorRoot -BasePath $repoRoot
} else {
  Join-Path $repoRoot 'vendor/icon-editor'
}
if (-not (Test-Path -LiteralPath $iconEditorRootResolved -PathType Container)) {
  throw "Icon editor root not found at '$iconEditorRootResolved'."
}

$workspaceResolved = if ($WorkspaceRoot) {
  Resolve-OptionalPath -Path $WorkspaceRoot -BasePath $repoRoot
} else {
  Join-Path $repoRoot 'tests/results/_agent/icon-editor/snapshots'
}
if (-not (Test-Path -LiteralPath $workspaceResolved -PathType Container)) {
  [void](New-Item -ItemType Directory -Path $workspaceResolved -Force)
}

$stageNameResolved = if ($StageName) {
  $StageName
} else {
  'host-prep-{0}' -f (Get-Date -Format 'yyyyMMddTHHmmss')
}

$versionsList = Convert-ToIntList -Values $Versions -Defaults @(2021) -Name 'Versions' -Validator { param($v) ($v -gt 2000) }
$bitnessList = Convert-ToIntList -Values $Bitness -Defaults @(32, 64) -Name 'Bitness' -Validator { param($b) ($b -in 32,64) }

$stageScript = Join-Path $repoRoot 'tools/icon-editor/Stage-IconEditorSnapshot.ps1'
$enableScript = Join-Path $repoRoot 'tools/icon-editor/Enable-DevMode.ps1'
$resetScript = Join-Path $repoRoot 'tools/icon-editor/Reset-IconEditorWorkspace.ps1'
$detectScript = Join-Path $repoRoot 'tools/Detect-RogueLV.ps1'
$closeScript = Join-Path $iconEditorRootResolved '.github/actions/close-labview/Close_LabVIEW.ps1'
$globalCloseScript = Join-Path $repoRoot 'tools/Close-LabVIEW.ps1'

foreach ($required in @($stageScript, $enableScript, $resetScript, $closeScript, $globalCloseScript)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required helper script '$required' was not found."
  }
}

$script:HostPrepCloseScriptPath = $globalCloseScript
$script:HostPrepDryRun = [bool]$DryRun
$script:HostPrepClosureEvents = @()

$resultsRoot = Join-Path $repoRoot 'tests/results'
if (-not (Test-Path -LiteralPath $resultsRoot -PathType Container)) {
  [void](New-Item -ItemType Directory -Path $resultsRoot -Force)
}

$stepTelemetry = [ordered]@{
  roguePre  = @{ skipped = [bool]$SkipRogueDetection; executed = $false }
  stage     = @{ skipped = [bool]$SkipStage; executed = $false }
  devMode   = @{ skipped = [bool]$SkipDevMode; executed = $false }
  close     = @{ skipped = [bool]$SkipClose; executed = $false }
  reset     = @{ skipped = [bool]$SkipReset; executed = $false }
  roguePost = @{ skipped = [bool]$SkipPostRogueDetection; executed = $false }
}

$safetyToggles = @{
  LV_SUPPRESS_UI       = '1'
  LV_NO_ACTIVATE       = '1'
  LV_CURSOR_RESTORE    = '1'
  LV_IDLE_WAIT_SECONDS = '2'
  LV_IDLE_MAX_WAIT_SECONDS = '5'
}
foreach ($entry in $safetyToggles.GetEnumerator()) {
  $current = [Environment]::GetEnvironmentVariable($entry.Key)
  if ([string]::IsNullOrWhiteSpace($current)) {
    Set-Item -Path ("Env:{0}" -f $entry.Key) -Value $entry.Value
  }
}

if ($DryRun) {
  Write-Host "[prep] Dry-run mode enabled. Only staging will execute (with -DryRun); other steps will be logged."
}

Invoke-RogueDetection -StageLabel 'pre' -ScriptPath $detectScript -ResultsDir $resultsRoot -LookBackSeconds $RogueLookBackSeconds -Skip:$SkipRogueDetection
if (-not $SkipRogueDetection) {
  $stepTelemetry.roguePre.executed = $true
}

if (-not $SkipStage) {
  $stageArgs = @{
    FixturePath     = $fixtureResolved
    WorkspaceRoot   = $workspaceResolved
    StageName       = $stageNameResolved
    DevModeVersions = $versionsList
    DevModeBitness  = $bitnessList
    DevModeOperation = $Operation
  }
  if ($IconEditorRoot) {
    $stageArgs.SourcePath = $iconEditorRootResolved
  }
  if ($DryRun) {
    $stageArgs.DryRun = $true
  }
  if ($SkipStageValidate) {
    $stageArgs.SkipValidate = $true
  }
  Write-Host "[prep] Staging icon-editor snapshot..."
  & $stageScript @stageArgs | Out-Null
  $stepTelemetry.stage.executed = $true
  Invoke-ClosureCheck -Context 'stage'
} else {
  Write-Host "[prep] Skipping snapshot staging (per flag)."
}

if (-not $SkipDevMode) {
  if ($DryRun) {
    Write-Host "[prep] (dry-run) would enable icon-editor dev mode for versions [$($versionsList -join ', ')] bitness [$($bitnessList -join ', ')]."
  } else {
    $devArgs = @{
      RepoRoot = $repoRoot
      IconEditorRoot = $iconEditorRootResolved
      Versions = $versionsList
      Bitness  = $bitnessList
      Operation = $Operation
    }
    Write-Host "[prep] Enabling icon-editor dev mode..."
    & $enableScript @devArgs | Out-Null
    $stepTelemetry.devMode.executed = $true
    Invoke-ClosureCheck -Context 'dev-mode'
  }
} else {
  Write-Host "[prep] Skipping dev-mode enable (per flag)."
}

if (-not $SkipClose) {
  if ($DryRun) {
    Write-Host "[prep] (dry-run) would close LabVIEW via Close_LabVIEW.ps1 for all targets."
  } else {
    foreach ($version in $versionsList) {
      foreach ($bit in $bitnessList) {
        Write-Host ("[prep] Closing LabVIEW {0} ({1}-bit)..." -f $version, $bit)
        & $closeScript `
          -MinimumSupportedLVVersion $version `
          -SupportedBitness $bit
      }
    }
    $stepTelemetry.close.executed = $true
    Invoke-ClosureCheck -Context 'close'
  }
} else {
  Write-Host "[prep] Skipping LabVIEW close (per flag)."
}

if (-not $SkipReset) {
  if ($DryRun) {
    Write-Host "[prep] (dry-run) would reset icon-editor workspace for all targets."
  } else {
    $resetArgs = @{
      RepoRoot = $repoRoot
      IconEditorRoot = $iconEditorRootResolved
      Versions = $versionsList
      Bitness = $bitnessList
    }
    Write-Host "[prep] Resetting icon-editor workspaces..."
    & $resetScript @resetArgs | Out-Null
    $stepTelemetry.reset.executed = $true
    Invoke-ClosureCheck -Context 'reset'
  }
} else {
  Write-Host "[prep] Skipping workspace reset (per flag)."
}

Invoke-RogueDetection -StageLabel 'post' -ScriptPath $detectScript -ResultsDir $resultsRoot -LookBackSeconds $RogueLookBackSeconds -Skip:$SkipPostRogueDetection
if (-not $SkipPostRogueDetection) {
  $stepTelemetry.roguePost.executed = $true
}

Invoke-ClosureCheck -Context 'final'

$summary = [pscustomobject]@{
  fixture      = $fixtureResolved
  versions     = $versionsList
  bitness      = $bitnessList
  stage        = $stageNameResolved
  workspace    = $workspaceResolved
  dryRun       = [bool]$DryRun
  operation    = $Operation
  steps        = $stepTelemetry
  closures     = $script:HostPrepClosureEvents
  telemetryPath = $null
}

try {
  $telemetryDir = Join-Path $resultsRoot '_agent' 'icon-editor' 'host-prep'
  if (-not (Test-Path -LiteralPath $telemetryDir -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $telemetryDir -Force)
  }
  $telemetryPayload = [ordered]@{
    schema      = 'icon-editor/host-prep@v1'
    recordedAt  = (Get-Date).ToString('o')
    fixture     = $fixtureResolved
    versions    = $versionsList
    bitness     = $bitnessList
    stage       = $stageNameResolved
    workspace   = $workspaceResolved
    dryRun      = [bool]$DryRun
    operation   = $Operation
    steps       = $stepTelemetry
    closures    = $script:HostPrepClosureEvents
  }
  $telemetryPath = Join-Path $telemetryDir ("host-prep-{0}.json" -f (Get-Date -Format 'yyyyMMddTHHmmssfff'))
  $telemetryPayload | ConvertTo-Json -Depth 8 | Out-File -FilePath $telemetryPath -Encoding utf8
  $summary.telemetryPath = $telemetryPath
} catch {
  Write-Warning ("[prep] Failed to write host-prep telemetry: {0}" -f $_.Exception.Message)
}

$summary
