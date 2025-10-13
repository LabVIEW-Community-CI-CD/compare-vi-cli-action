#Requires -Version 7.0
<#
.SYNOPSIS
  One-button end-to-end CI trigger and artifact post-processing for the standing priority issue.

.DESCRIPTION
  - Dispatches Validate and CI Orchestrated (strategy=single, include_integration=true)
  - Waits for completion, downloads artifacts locally, and writes a concise summary
  - Produces a single local report under tests/results/_onebutton/

.PARAMETER Ref
  Git ref/branch to dispatch against (default: current branch or 'develop').

.PARAMETER IncludeIntegration
  'true' or 'false' for include_integration input (default: 'true').

.PARAMETER Strategy
  Orchestrated strategy ('single' or 'matrix', default: 'single').

.PARAMETER AutoOpen
  When set, attempts to open the local summary in the default viewer.
#>
[CmdletBinding()]
param(
  [string]$Ref,
  [ValidateSet('true','false')][string]$IncludeIntegration = 'true',
  [ValidateSet('single','matrix')][string]$Strategy = 'single',
  [switch]$AutoOpen,
  [switch]$UseContainerValidate,
  [switch]$SkipRemoteValidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Tool {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required tool not found: $Name"
  }
}

function Get-RepoName() {
  $repo = $null
  try { $repo = (gh repo view --json nameWithOwner --jq .nameWithOwner) } catch {}
  if (-not $repo) { $repo = $env:GITHUB_REPOSITORY }
  if (-not $repo) {
    try {
      $url = git remote get-url origin 2>$null
      if ($url -match 'github\.com[:/](.+?/.+?)(?:\.git)?$') { $repo = $Matches[1] }
    } catch {}
  }
  if (-not $repo) { throw 'Unable to determine repository. Ensure gh is authenticated or set GITHUB_REPOSITORY.' }
  return $repo
}

function Get-DefaultRef() {
  if ($Ref) { return $Ref }
  try {
    $br = git rev-parse --abbrev-ref HEAD 2>$null
    if ($br) { return $br.Trim() }
  } catch {}
  return 'develop'
}

function New-SampleId() {
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $rnd = -join ((48..57 + 97..122) | Get-Random -Count 4 | ForEach-Object {[char]$_})
  return "ts-$ts-$rnd"
}

function Dispatch-Workflow {
  param(
    [Parameter(Mandatory=$true)][string]$Workflow,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Ref,
    [hashtable]$Inputs
  )
  $args = @('workflow','run',$Workflow,'-R',$Repo,'-r',$Ref)
  if ($Inputs) {
    foreach ($k in $Inputs.Keys) { $args += @('-f',"$k=$($Inputs[$k])") }
  }
  gh @args | Out-Null
}

function Resolve-RunId {
  param(
    [Parameter(Mandatory=$true)][string]$Workflow,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Ref
  )
  Start-Sleep -Seconds 3
  $json = gh run list -R $Repo --workflow $Workflow --branch $Ref --json databaseId,headBranch,createdAt -L 1 2>$null
  if (-not $json) { return $null }
  $arr = $json | ConvertFrom-Json -ErrorAction Stop
  if ($arr -isnot [System.Array]) { $arr = @($arr) }
  if ($arr.Count -gt 0) { return [string]$arr[0].databaseId }
  return $null
}

function Wait-Run {
  param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$RunId,
    [int]$TimeoutSeconds = 1800,
    [int]$PollSeconds = 10
  )
  $start = Get-Date
  while ($true) {
    $r = $null
    try { $r = gh api "repos/$Repo/actions/runs/$RunId" | ConvertFrom-Json } catch {}
    if ($r) {
      Write-Host ("[run {0}] status={1} conclusion={2}" -f $RunId, $r.status, ($r.conclusion ?? ''))
      if ($r.status -eq 'completed') { return $r }
    } else {
      Write-Host ("[run {0}] status=unknown" -f $RunId)
    }
    if ((Get-Date) - $start -gt [TimeSpan]::FromSeconds($TimeoutSeconds)) { throw "Timeout waiting for run $RunId" }
    Start-Sleep -Seconds $PollSeconds
  }
}

function Download-RunArtifacts {
  param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$RunId,
    [Parameter(Mandatory=$true)][string]$TargetDir
  )
  New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
  gh run download $RunId -R $Repo -D $TargetDir | Out-Null
}

function Write-LocalSummary {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)]$ValidateRun,
    [Parameter(Mandatory=$true)]$OrchRun,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Ref,
    [Parameter(Mandatory=$true)][string]$SampleId,
    [Parameter(Mandatory=$true)][string]$ArtifactsDir,
    [string]$ValidateLogPath
  )
  $lines = @()
  $lines += "# One-Button CI Summary"
  $lines += ''
  $lines += ('- Repo: {0}' -f $Repo)
  $lines += ('- Ref: {0}' -f $Ref)
  $lines += ('- SampleId: {0}' -f $SampleId)
  $lines += ''
  $lines += '## Runs'
  $lines += ('- Validate: {0} ({1})' -f $ValidateRun.html_url, $ValidateRun.conclusion)
  if ($ValidateLogPath) {
    try {
      $logResolved = Resolve-Path $ValidateLogPath
      $lines += ('  - Log: {0}' -f $logResolved)
    } catch {
      $lines += ('  - Log: {0}' -f $ValidateLogPath)
    }
  }
  $lines += ('- Orchestrated: {0} ({1})' -f $OrchRun.html_url, $OrchRun.conclusion)
  $lines += ''
  $lines += '## Artifacts'
  $lines += ('- Downloaded to: {0}' -f (Resolve-Path $ArtifactsDir))
  
  $co = Get-ChildItem -Recurse -Filter 'compare-outcome.json' -Path $ArtifactsDir -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($co) {
    try {
      $data = Get-Content -LiteralPath $co.FullName -Raw | ConvertFrom-Json -Depth 6
      $lines += ''
      $lines += '## Compare Outcome'
      $lines += ('- Source: {0}' -f ($data.source ?? 'n/a'))
      if ($data.exitCode -ne $null) { $lines += ('- Exit: {0}' -f $data.exitCode) }
      if ($data.diff -ne $null) { $lines += ('- Diff: {0}' -f $data.diff) }
      if ($data.durationMs -ne $null) { $lines += ('- DurationMs: {0}' -f $data.durationMs) }
      if ($data.cliPath) { $lines += ('- CLI Path: {0}' -f $data.cliPath) }
      if ($data.command) {
        $cmd=[string]$data.command; if ($cmd.Length -gt 240) { $cmd = $cmd.Substring(0,240)+'…' }
        $lines += ('- Command: {0}' -f $cmd)
      }
    } catch {}
  }

  $dash = Get-ChildItem -Recurse -Filter 'dashboard.html' -Path $ArtifactsDir -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($dash) {
    $lines += ''
    $lines += '## Dev Dashboard'
    $lines += ('- HTML: {0}' -f (Resolve-Path $dash.FullName))
  }

  $trace = Get-ChildItem -Recurse -Filter 'trace-matrix.json' -Path $ArtifactsDir -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($trace) {
    $lines += ''
    $lines += '## Traceability'
    $lines += ('- Matrix: {0}' -f (Resolve-Path $trace.FullName))
  }

  $lines += ''
  $lines += '## Re-run With Same Inputs'
  $lines += ''
  $lines += ('$ /run orchestrated strategy={0} include_integration={1} sample_id={2}' -f $env:STRATEGY,$env:INCLUDE_INTEGRATION,$SampleId)
  $lines += ('- gh: gh workflow run "ci-orchestrated.yml" -r "{0}" -f sample_id={1} -f include_integration={2} -f strategy={3}' -f $Ref,$SampleId,$env:INCLUDE_INTEGRATION,$env:STRATEGY)

  $lines -join "`n" | Out-File -FilePath $Path -Encoding utf8
}

# MAIN
Assert-Tool gh
try { Assert-Tool git } catch {}

try {
  & (Join-Path $PSScriptRoot 'Get-BranchState.ps1') | Out-Null
} catch {
  Write-Warning ("[branch-state] Unable to determine branch status: {0}" -f $_.Exception.Message)
}

$containerLog = $null
$repo = Get-RepoName
$branch = Get-DefaultRef
$sid = New-SampleId

$env:INCLUDE_INTEGRATION = $IncludeIntegration
$env:STRATEGY = $Strategy

Write-Host ("[onebutton] Repo={0} Ref={1} SampleId={2}" -f $repo,$branch,$sid)

# Optional local prechecks (best-effort)
try { pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'PrePush-Checks.ps1') | Out-Host } catch { Write-Host "::notice::PrePush checks skipped: $_" }

# 1) Validate stage (optional container, optional remote)
if ($UseContainerValidate) {
  Write-Host '[onebutton] Running Validate inside container...'
  try {
    $containerResult = pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Run-ValidateContainer.ps1') -PassThru
    if ($containerResult) { $containerLog = $containerResult.LogPath }
  } catch {
    throw "Container validate failed: $_"
  }
}

if (-not $SkipRemoteValidate) {
  Write-Host '[onebutton] Dispatching Validate...'
  Dispatch-Workflow -Workflow 'validate.yml' -Repo $repo -Ref $branch -Inputs @{ sample_id = $sid }
  $valId = Resolve-RunId -Workflow 'validate.yml' -Repo $repo -Ref $branch
  if (-not $valId) { throw 'Unable to locate Validate run after dispatch.' }
  $val = Wait-Run -Repo $repo -RunId $valId -TimeoutSeconds 900 -PollSeconds 8
} else {
  $val = [pscustomobject]@{
    html_url = '(local container)'
    conclusion = 'success'
  }
  $valId = $null
}

# 2) Dispatch Orchestrated
Write-Host '[onebutton] Dispatching CI Orchestrated (single)...'
Dispatch-Workflow -Workflow 'ci-orchestrated.yml' -Repo $repo -Ref $branch -Inputs @{ sample_id = $sid; include_integration = $IncludeIntegration; strategy = $Strategy }
$orchId = Resolve-RunId -Workflow 'ci-orchestrated.yml' -Repo $repo -Ref $branch
if (-not $orchId) { throw 'Unable to locate orchestrated run after dispatch.' }
$orch = Wait-Run -Repo $repo -RunId $orchId -TimeoutSeconds 3600 -PollSeconds 12

# 3) Download artifacts and write local summary
$root = Join-Path $PWD 'tests/results/_onebutton'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$orchDir = Join-Path $root ("orchestrated-" + $orchId)
$valDir = $null
if ($valId) {
  $valDir = Join-Path $root ("validate-" + $valId)
  Download-RunArtifacts -Repo $repo -RunId $valId -TargetDir $valDir
}
Download-RunArtifacts -Repo $repo -RunId $orchId -TargetDir $orchDir

$summary = Join-Path $root 'summary.md'
Write-LocalSummary -Path $summary -ValidateRun $val -OrchRun $orch -Repo $repo -Ref $branch -SampleId $sid -ArtifactsDir $orchDir -ValidateLogPath $containerLog

Write-Host ("[onebutton] Summary -> {0}" -f (Resolve-Path $summary))
if ($AutoOpen) {
  try {
    if ($IsWindows) { Start-Process $summary } else { & xdg-open $summary 2>$null }
  } catch {}
}

if ($val.conclusion -ne 'success' -or $orch.conclusion -ne 'success') {
  Write-Host '::warning::OneButton CI completed with failures. See summary.'
  exit 1
}

Write-Host '[onebutton] All green.'
exit 0

