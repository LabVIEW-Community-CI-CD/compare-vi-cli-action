[CmdletBinding()]
param(
  [switch]$Stage,
  [switch]$Commit,
  [switch]$Push,
  [string]$PushTarget = 'standing',
  [switch]$CreatePR,
  [switch]$OpenResults
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Get-Location).Path
$summary = @()
$summaryPath = Join-Path $workspace 'tests/results/_agent/onebutton-summary.md'

if (Test-Path (Join-Path $workspace 'tools' 'Save-WorkInProgress.ps1')) {
  try {
    & pwsh '-NoLogo' '-NoProfile' '-File' (Join-Path $workspace 'tools' 'Save-WorkInProgress.ps1') '-RepositoryRoot' $workspace '-Name' 'one-button'
  } catch {
    Write-Warning ("Failed to capture work-in-progress snapshot: {0}" -f $_.Exception.Message)
  }
}

function Add-Summary {
  param([string]$Step,[string]$Status,[TimeSpan]$Duration,[string]$Message)
  $script:summary += [pscustomobject]@{ Step = $Step; Status = $Status; Duration = $Duration; Message = $Message }
}

function Write-SummaryFile {
  if (-not $summary) { return }
  $dir = Split-Path -Parent $summaryPath
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $lines = @('# One-Button Validate Summary','')
  $lines += '| Step | Status | Duration | Message |'
  $lines += '| --- | --- | --- | --- |'
  foreach ($item in $summary) {
    $duration = if ($item.Duration) { ('{0:c}' -f $item.Duration) } else { '' }
    $msg = $item.Message.Replace('|','\|')
    $lines += ('| {0} | {1} | {2} | {3} |' -f $item.Step,$item.Status,$duration,$msg)
  }
  $lines | Set-Content -LiteralPath $summaryPath -Encoding utf8
  Write-Host "Summary written to $summaryPath"
}

function Invoke-Step {
  param([string]$Name,[scriptblock]$Action)
  Write-Host "==> $Name"
  $start = Get-Date
  try {
    & $Action
    $exit = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }
    if ($exit -ne 0) {
      throw "Exit code $exit"
    }
    Add-Summary -Step $Name -Status 'OK' -Duration ((Get-Date) - $start) -Message ''
  } catch {
    $msg = $_.Exception.Message
    Add-Summary -Step $Name -Status 'FAIL' -Duration ((Get-Date) - $start) -Message $msg
    Write-SummaryFile
    throw "Step '$Name' failed: $msg"
  }
}

function Invoke-CommandWithExit {
  param([string]$Command,[string[]]$Arguments,[string]$FailureMessage)
  & $Command @Arguments
  $exit = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }
  if ($exit -ne 0) {
    if (-not $FailureMessage) { $FailureMessage = "$Command exited $exit" }
    throw $FailureMessage
  }
}

$validateSteps = @(
  @{ Name = 'Tracked build artifacts'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Check-TrackedBuildArtifacts.ps1','-AllowListPath','.ci/build-artifacts-allow.txt') -FailureMessage 'Tracked build artifacts detected.' } },
  @{ Name = 'PrePush gates (actionlint + schemas)'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/PrePush-Checks.ps1') -FailureMessage 'PrePush checks failed.' } },
  @{ Name = 'Lint inline-if format (-f)'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Lint-InlineIfInFormat.ps1') -FailureMessage 'Inline-if format lint failed.' } },
  @{ Name = 'Markdown lint (changed)'; Action = { Invoke-CommandWithExit -Command 'npm' -Arguments @('run','lint:md:changed') -FailureMessage 'Markdown lint (changed) failed.' } },
  @{ Name = 'Docs links check'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @(
      '-NoLogo','-NoProfile','-File','./tools/Check-DocsLinks.ps1','-Path','docs',
      '-AllowListPath','.ci/link-allowlist.txt','-OutputJson','tests/results/lint/docs-links.json') -FailureMessage 'Docs link check failed.' } },
  @{ Name = 'Workflow drift (auto-fix)'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Check-WorkflowDrift.ps1','-AutoFix') -FailureMessage 'Workflow drift check failed.' } },
  @{ Name = 'Loop determinism (enforced)'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Run-LoopDeterminism.ps1','-FailOnViolation') -FailureMessage 'Loop determinism lint failed.' } },
  @{ Name = 'Derive environment snapshot'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Write-DerivedEnv.ps1') -FailureMessage 'Derive environment snapshot failed.' } },
  @{ Name = 'Session index validation'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Run-SessionIndexValidation.ps1') -FailureMessage 'Session index validation failed.' } },
  @{ Name = 'Fixture validation (enforced)'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Run-FixtureValidation.ps1') -FailureMessage 'Fixture validation failed.' } },
  @{ Name = 'Tool versions'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Print-ToolVersions.ps1') -FailureMessage 'Tool version check failed.' } },
  @{ Name = 'Labels sync (auto)'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Invoke-LabelsSync.ps1','-Auto') -FailureMessage 'Labels sync check failed.' } },
  @{ Name = 'Verify validation outputs'; Action = { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Assert-ValidateOutputs.ps1','-ResultsRoot','tests/results','-RequireDeltaJson') -FailureMessage 'Validation outputs verification failed.' } }
)

foreach ($step in $validateSteps) {
  Invoke-Step -Name $step.Name -Action $step.Action
}

if ($Stage -and -not ($Commit -or $Push -or $CreatePR)) {
  Invoke-Step -Name 'Prepare standing commit (stage)' -Action {
    Invoke-CommandWithExit -Command 'pwsh' -Arguments @(
      '-NoLogo','-NoProfile','-File','./tools/Prepare-StandingCommit.ps1',
      '-RepositoryRoot',(Get-Location).Path
    ) -FailureMessage 'Prepare-StandingCommit (stage) failed.'
  }
}

if ($Stage -or $Commit -or $Push -or $CreatePR) {
  Invoke-Step -Name 'Workflow drift (stage)' -Action { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Check-WorkflowDrift.ps1','-AutoFix','-Stage') -FailureMessage 'Workflow drift stage failed.' }
}

  if ($Commit) {
    Invoke-Step -Name 'Workflow drift commit' -Action { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Check-WorkflowDrift.ps1','-AutoFix','-Stage','-CommitMessage','Normalize: ci-orchestrated via ruamel (#127)') -FailureMessage 'Workflow drift commit failed.' }
}

if ($Stage -or $Commit) {
  Invoke-Step -Name 'PrePush checks (post-stage)' -Action { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/PrePush-Checks.ps1') -FailureMessage 'PrePush checks failed after staging.' }
}

if ($Commit -or $Push -or $CreatePR) {
  Invoke-Step -Name 'Prepare standing commit (auto)' -Action {
    Invoke-CommandWithExit -Command 'pwsh' -Arguments @(
      '-NoLogo','-NoProfile','-File','./tools/Prepare-StandingCommit.ps1',
      '-RepositoryRoot',(Get-Location).Path,
      '-AutoCommit'
    ) -FailureMessage 'Prepare-StandingCommit (auto) failed.'
  }
}

if ($Push -or $CreatePR) {
  Invoke-Step -Name 'Post-commit automation' -Action {
    $args = @(
      '-NoLogo','-NoProfile',
      '-File',(Join-Path $workspace 'tools' 'After-CommitActions.ps1'),
      '-RepositoryRoot',$workspace
    )
    if ($Push) { $args += '-Push' }
    if ($CreatePR) { $args += '-CreatePR' }
    if ($Push -or $CreatePR) { $args += '-CloseIssue' }
    if ($PushTarget) {
      $args += '-PushTarget'
      $args += $PushTarget
    }
    Invoke-CommandWithExit -Command 'pwsh' -Arguments $args -FailureMessage 'Post-commit automation failed.'
  }
}

Write-SummaryFile

if ($OpenResults -or -not ($Stage -or $Commit -or $Push -or $CreatePR)) {
  $resultsDir = Join-Path $workspace 'tests/results'
  if (Test-Path -LiteralPath $resultsDir) {
    try { Invoke-Item (Resolve-Path $resultsDir) } catch {}
  }
}

Write-Host 'One-button validate completed successfully.'
