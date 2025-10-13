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
.PARAMETER SkipDotnetCliBuild
  Skip building the CompareVI .NET CLI inside the dotnet SDK container (outputs to dist/comparevi-cli by default).
#>
param(
  [switch]$SkipActionlint,
  [switch]$SkipMarkdown,
  [switch]$SkipDocs,
  [switch]$SkipWorkflow,
  [switch]$FailOnWorkflowDrift,
  [switch]$SkipDotnetCliBuild,
  [string]$ToolsImageTag,
  [switch]$UseToolsImage
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
    [string]$Label
  )
  $labelText = if ($Label) { $Label } else { $Image }
  Write-Host ("[docker] {0}" -f $labelText) -ForegroundColor Cyan
  $cmd = @('docker','run') + $commonArgs + @($Image) + $Arguments
  Write-Host ("`t" + ($cmd -join ' ')) -ForegroundColor DarkGray
  & docker run @commonArgs $Image @Arguments
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

# Build CLI via tools image or plain SDK
if (-not $SkipDotnetCliBuild) {
  $cliOutput = 'dist/comparevi-cli'
  $projectPath = 'src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj'
  if (Test-Path -LiteralPath $cliOutput) {
    Remove-Item -LiteralPath $cliOutput -Recurse -Force -ErrorAction SilentlyContinue
  }
  $publishCommand = "dotnet publish $projectPath -c Release -nologo -o $cliOutput"
  if ($UseToolsImage -and $ToolsImageTag) {
    Invoke-Container -Image $ToolsImageTag `
      -Arguments @('bash','-lc',$publishCommand) `
      -Label 'dotnet-cli-build (tools)'
  } else {
    Invoke-Container -Image 'mcr.microsoft.com/dotnet/sdk:8.0' `
      -Arguments @('bash','-lc',$publishCommand) `
      -Label 'dotnet-cli-build'
  }
}

if ($UseToolsImage -and $ToolsImageTag) {
  if (-not $SkipActionlint) {
    Invoke-Container -Image $ToolsImageTag -Arguments @('actionlint','-color') -Label 'actionlint (tools)'
  }
  if (-not $SkipMarkdown) {
    $cmd = 'markdownlint "**/*.md" --config .markdownlint.jsonc --ignore node_modules --ignore bin --ignore vendor'
    Invoke-Container -Image $ToolsImageTag -Arguments @('bash','-lc',$cmd) -AcceptExitCodes @(0,1) -Label 'markdownlint (tools)'
  }
  if (-not $SkipDocs) {
    Invoke-Container -Image $ToolsImageTag -Arguments @('pwsh','-NoLogo','-NoProfile','-File','tools/Check-DocsLinks.ps1','-Path','docs') -Label 'docs-links (tools)'
  }
  if (-not $SkipWorkflow) {
    $checkCmd = 'python tools/workflows/update_workflows.py --check .github/workflows/pester-selfhosted.yml .github/workflows/fixture-drift.yml .github/workflows/ci-orchestrated.yml .github/workflows/ci-orchestrated-v2.yml .github/workflows/pester-integration-on-label.yml .github/workflows/smoke.yml .github/workflows/compare-artifacts.yml'
    $wfCode = Invoke-Container -Image $ToolsImageTag -Arguments @('bash','-lc',$checkCmd) -AcceptExitCodes @(0,3) -Label 'workflow-drift (tools)'
    if ($FailOnWorkflowDrift -and $wfCode -eq 3) {
      Write-Host 'Workflow drift detected (enforced).' -ForegroundColor Red
      exit 3
    }
  }
} else {
  if (-not $SkipActionlint) {
    Invoke-Container -Image 'rhysd/actionlint:1.7.7' -Arguments @('-color') -Label 'actionlint'
  }
  if (-not $SkipMarkdown) {
    $cmd = @'
npm install -g markdownlint-cli && \
markdownlint "**/*.md" --config .markdownlint.jsonc --ignore node_modules --ignore bin --ignore vendor
'@
    Invoke-Container -Image 'node:20-alpine' -Arguments @('sh','-lc',$cmd) -AcceptExitCodes @(0,1) -Label 'markdownlint'
  }
  if (-not $SkipDocs) {
    Invoke-Container -Image 'mcr.microsoft.com/powershell:7.4-debian-12' -Arguments @('pwsh','-NoLogo','-NoProfile','-File','tools/Check-DocsLinks.ps1','-Path','docs') -Label 'docs-links'
  }
  if (-not $SkipWorkflow) {
    $checkCmd = @'
pip install -q ruamel.yaml && \
python tools/workflows/update_workflows.py --check .github/workflows/pester-selfhosted.yml .github/workflows/fixture-drift.yml .github/workflows/ci-orchestrated.yml .github/workflows/ci-orchestrated-v2.yml .github/workflows/pester-integration-on-label.yml .github/workflows/smoke.yml .github/workflows/compare-artifacts.yml
'@
    $wfCode = Invoke-Container -Image 'python:3.12-alpine' -Arguments @('sh','-lc',$checkCmd) -AcceptExitCodes @(0,3) -Label 'workflow-drift'
    if ($FailOnWorkflowDrift -and $wfCode -eq 3) {
      Write-Host 'Workflow drift detected (enforced).' -ForegroundColor Red
      exit 3
    }
  }
}

Write-Host 'Non-LabVIEW container checks completed.' -ForegroundColor Green
