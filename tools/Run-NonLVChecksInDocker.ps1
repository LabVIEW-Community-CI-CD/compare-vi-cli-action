#Requires -Version 7.0
<#
.SYNOPSIS
  Runs non-LabVIEW validation checks (actionlint, markdownlint, docs links, workflow drift)
  inside Docker containers for consistent local results.

.DESCRIPTION
  Executes the repository's non-LV tooling in containerized environments to mirror CI behaviour
  while keeping the working tree deterministic. Each check mounts the repository read/write and
  runs against the current workspace.

  Exit codes:
    - 0 : success or expected drift (workflow drift exits 3 normally)
    - non-zero : first failing check exit code is propagated.

.PARAMETER SkipActionlint
  Skip the actionlint check.
.PARAMETER SkipMarkdown
  Skip the markdownlint check.
.PARAMETER SkipDocs
  Skip the docs link checker.
.PARAMETER SkipWorkflow
  Skip the workflow drift check.
#>
param(
  [switch]$SkipActionlint,
  [switch]$SkipMarkdown,
  [switch]$SkipDocs,
  [switch]$SkipWorkflow,
  [switch]$FailOnWorkflowDrift,
  [switch]$SkipWatch,
  [string]$WatchRunId,
  [string]$WatchRepo,
  [int]$WatchPollSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)) {
  throw "Docker CLI not found. Install Docker Desktop or Docker Engine to run containerized checks."
}

function Get-DockerHostPath {
  param([string]$Path = '.')
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  if ($IsWindows) {
    $drive = $resolved.Substring(0,1).ToLowerInvariant()
    $rest = $resolved.Substring(2).Replace('\','/')
    return "/$drive/$rest"
  }
  return $resolved
}

$hostPath = Get-DockerHostPath '.'
$volumeSpec = "${hostPath}:/work"
$commonArgs = @('--rm','-v', $volumeSpec,'-w','/work')

function Invoke-Container {
  param(
    [string]$Image,
    [string[]]$Arguments,
    [int[]]$AcceptExitCodes = @(0),
    [string]$Label,
    [string[]]$EnvNames
  )
  $labelText = if ($Label) { $Label } else { $Image }
  Write-Host ("[docker] {0}" -f $labelText) -ForegroundColor Cyan
  $envArgs = @()
  if ($EnvNames) {
    foreach ($n in $EnvNames) {
      $val = [Environment]::GetEnvironmentVariable($n)
      if ($val -and $val -ne '') { $envArgs += @('-e', $n) }
    }
  }
  $cmd = @('docker','run') + $commonArgs + $envArgs + @($Image) + $Arguments
  Write-Host ("`t" + ($cmd -join ' ')) -ForegroundColor DarkGray
  & docker run @commonArgs @envArgs $Image @Arguments
  $code = $LASTEXITCODE
  if ($AcceptExitCodes -notcontains $code) {
    throw "Container '$labelText' exited with code $code."
  }
  if ($code -ne 0) {
    Write-Host ("[docker] {0} completed with exit code {1} (accepted)" -f $labelText, $code) -ForegroundColor Yellow
  } else {
    Write-Host ("[docker] {0} OK" -f $labelText) -ForegroundColor Green
  }
  return $code
}

if (-not $SkipActionlint) {
  Invoke-Container -Image 'rhysd/actionlint:1.7.7' `
    -Arguments @('-color') `
    -Label 'actionlint'
}

if (-not $SkipMarkdown) {
  $cmd = @'
npm install -g markdownlint-cli && \
markdownlint "**/*.md" --config .markdownlint.jsonc --ignore node_modules --ignore bin --ignore vendor
'@
  Invoke-Container -Image 'node:20-alpine' `
    -Arguments @('sh','-lc',$cmd) `
    -AcceptExitCodes @(0,1) `
    -Label 'markdownlint'
}

if (-not $SkipDocs) {
  Invoke-Container -Image 'mcr.microsoft.com/powershell:7.4-debian-12' `
    -Arguments @('pwsh','-NoLogo','-NoProfile','-File','tools/Check-DocsLinks.ps1','-Path','docs') `
    -Label 'docs-links'
}

if (-not $SkipWorkflow) {
  $checkCmd = @'
pip install -q ruamel.yaml && \
python tools/workflows/update_workflows.py --check .github/workflows/pester-selfhosted.yml .github/workflows/fixture-drift.yml .github/workflows/ci-orchestrated.yml .github/workflows/ci-orchestrated-v2.yml .github/workflows/pester-integration-on-label.yml .github/workflows/smoke.yml .github/workflows/compare-artifacts.yml
'@
  $wfCode = Invoke-Container -Image 'python:3.12-alpine' `
    -Arguments @('sh','-lc',$checkCmd) `
    -AcceptExitCodes @(0,3) `
    -Label 'workflow-drift'
  if ($FailOnWorkflowDrift -and $wfCode -eq 3) {
    Write-Host 'Workflow drift detected (enforced).' -ForegroundColor Red
    exit 3
  }
}

if (-not $SkipWatch -and $WatchRunId) {
  $envNames = @()
  if ($env:GH_TOKEN) { $envNames += 'GH_TOKEN' }
  elseif ($env:GITHUB_TOKEN) { $envNames += 'GITHUB_TOKEN' }
  else { Write-Warning 'No GH_TOKEN/GITHUB_TOKEN set; watcher may not be able to access job logs/artifacts.' }
  $watchArgs = @('pwsh','-NoLogo','-NoProfile','-File','tools/Watch-OrchestratedRun.ps1','-RunId',"$WatchRunId")
  if ($WatchRepo) { $watchArgs += @('-Repo',"$WatchRepo") }
  if ($WatchPollSeconds -ne 15) { $watchArgs += @('-PollSeconds',"$WatchPollSeconds") }
  Invoke-Container -Image 'mcr.microsoft.com/powershell:7.4-debian-12' `
    -Arguments $watchArgs `
    -EnvNames $envNames `
    -Label 'watch-orchestrated'
}

Write-Host 'Non-LabVIEW container checks completed.' -ForegroundColor Green
