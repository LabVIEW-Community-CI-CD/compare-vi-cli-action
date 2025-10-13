[CmdletBinding()]
param(
  [switch]$Stage,
  [switch]$Commit,
  [switch]$Push,
  [switch]$CreatePR,
  [switch]$OpenResults
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Get-Location).Path
$summary = @()
$summaryPath = Join-Path $workspace 'tests/results/_agent/onebutton-summary.md'

function Resolve-StandingPriority {
  param([string]$RepoRoot)
  $scriptPath = Join-Path $RepoRoot 'tools' 'Get-StandingPriority.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { return $null }
  try {
    $json = pwsh -NoLogo -NoProfile -File $scriptPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    return $json | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

$standingPriority = Resolve-StandingPriority -RepoRoot $workspace
$standingIssueNumber = if ($standingPriority -and $standingPriority.number) { [int]$standingPriority.number } else { $null }
$standingIssueRef = if ($standingIssueNumber) { "(#$standingIssueNumber)" } else { '(standing priority)' }
$standingIssueLabel = if ($standingIssueNumber) { "#$standingIssueNumber" } else { 'standing priority issue' }
$standingIssueTitle = if ($standingPriority -and $standingPriority.title) { $standingPriority.title } else { 'standing priority issue' }

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

if ($Stage -or $Commit -or $Push -or $CreatePR) {
  Invoke-Step -Name 'Workflow drift (stage)' -Action { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Check-WorkflowDrift.ps1','-AutoFix','-Stage') -FailureMessage 'Workflow drift stage failed.' }
}

if ($Commit) {
Invoke-Step -Name 'Workflow drift commit' -Action {
  $commitMessage = "Normalize: ci-orchestrated via ruamel $standingIssueRef"
  Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/Check-WorkflowDrift.ps1','-AutoFix','-Stage','-CommitMessage',$commitMessage) -FailureMessage 'Workflow drift commit failed.'
}
}

if ($Stage -or $Commit) {
  Invoke-Step -Name 'PrePush checks (post-stage)' -Action { Invoke-CommandWithExit -Command 'pwsh' -Arguments @('-NoLogo','-NoProfile','-File','./tools/PrePush-Checks.ps1') -FailureMessage 'PrePush checks failed after staging.' }
}

if ($Push) {
  Invoke-Step -Name 'Push branch' -Action {
    $branch = git rev-parse --abbrev-ref HEAD
    $remoteUrl = git config --get remote.origin.url 2>$null
    if (-not $remoteUrl) {
      Write-Host '::notice::No origin remote configured; skipping push.'
      return
    }
    git ls-remote --heads origin 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Host '::notice::Cannot reach origin; skipping push.'
      return
    }
    git rev-parse --abbrev-ref --symbolic-full-name 'HEAD@{upstream}' 2>$null
    if ($LASTEXITCODE -eq 0) {
      git push
    } else {
      git push --set-upstream origin $branch
    }
    if ($LASTEXITCODE -ne 0) { throw "git push exited $LASTEXITCODE" }
  }
}

if ($CreatePR) {
  $prStepName = if ($standingIssueNumber) { "Create/Update PR (#$standingIssueNumber)" } else { 'Create/Update PR (Standing Priority)' }
  Invoke-Step -Name $prStepName -Action {
    $branch = git rev-parse --abbrev-ref HEAD
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
      Write-Host '::notice::gh CLI not available; skipping PR step.'
      return
    }
    gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Host '::notice::gh not authenticated; skipping PR step.'
      return
    }
    $title = "Normalize workflows and local Validate mirrors $standingIssueRef"
    $body = "Automated workflow normalization and Validate task updates for $standingIssueLabel."
    $existingJson = gh pr view --json number --head $branch 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingJson) {
      $pr = $existingJson | ConvertFrom-Json
      gh pr edit $pr.number --title $title --body $body | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "gh pr edit failed ($LASTEXITCODE)" }
    } else {
      gh pr create --base develop --head $branch --title $title --body $body | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "gh pr create failed ($LASTEXITCODE)" }
    }
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
