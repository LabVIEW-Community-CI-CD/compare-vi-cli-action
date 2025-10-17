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
.PARAMETER ExcludeWorkflowPaths
  Paths to omit from the workflow drift check (subset of the default targets).
#>
param(
  [switch]$SkipActionlint,
  [switch]$SkipMarkdown,
  [switch]$SkipDocs,
  [switch]$SkipWorkflow,
  [switch]$FailOnWorkflowDrift,
  [switch]$SkipDotnetCliBuild,
  [string]$ToolsImageTag,
  [switch]$UseToolsImage,
  [string[]]$ExcludeWorkflowPaths
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
    $rest = $resolved.Substring(2).Replace('\','/').TrimStart('/')
    return "/$drive/$rest"
  }
  return $resolved
}

$hostPath = Get-DockerHostPath '.'
$volumeSpec = "${hostPath}:/work"
$commonArgs = @('--rm','-v', $volumeSpec,'-w','/work')
# Forward git SHA when available for traceability
$buildSha = $null
try { $buildSha = (git rev-parse HEAD).Trim() } catch { $buildSha = $null }
if (-not $buildSha) { $buildSha = $env:GITHUB_SHA }
if ($buildSha) { $commonArgs += @('-e', "BUILD_GIT_SHA=$buildSha") }
$workflowTargets = @(
  '.github/workflows/pester-selfhosted.yml',
  '.github/workflows/fixture-drift.yml',
  '.github/workflows/ci-orchestrated.yml',
  '.github/workflows/pester-integration-on-label.yml',
  '.github/workflows/smoke.yml',
  '.github/workflows/compare-artifacts.yml'
)

if ($ExcludeWorkflowPaths) {
  $workflowTargets = $workflowTargets | Where-Object { $_ -notin $ExcludeWorkflowPaths }
}

if (-not $workflowTargets) {
  $SkipWorkflow = $true
}

function ConvertTo-SingleQuotedList {
  param([string[]]$Values)
  if (-not $Values) { return '' }
  return ($Values | ForEach-Object { "'$_'" }) -join ' '
}

function Test-WorkflowDriftPending {
  param([string[]]$Paths)
  try {
    $output = git status --porcelain -- @Paths
    return [bool]$output
  } catch {
    Write-Verbose "git status check failed: $_"
    return $true
  }
}

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
  if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    Write-Host ("[docker] CompareVI CLI project not found at {0}; skipping build." -f $projectPath) -ForegroundColor Yellow
  } else {
    if (Test-Path -LiteralPath $cliOutput) {
      Remove-Item -LiteralPath $cliOutput -Recurse -Force -ErrorAction SilentlyContinue
    }
    $publishCommand = @'
rm -rf src/CompareVi.Shared/obj src/CompareVi.Tools.Cli/obj || true
if [ -n "$BUILD_GIT_SHA" ]; then
  IV="0.1.0+${BUILD_GIT_SHA}"
else
  IV="0.1.0+local"
fi
'@
    $pubLine = 'dotnet publish "' + $projectPath + '" -c Release -nologo -o "' + $cliOutput + '" -p:UseAppHost=false -p:InformationalVersion="$IV"'
    $publishCommand = $publishCommand + "`n" + $pubLine
    # Build with official .NET SDK container to avoid file-permission quirks in tools image
    Invoke-Container -Image 'mcr.microsoft.com/dotnet/sdk:8.0' `
      -Arguments @('bash','-lc',$publishCommand) `
      -Label 'dotnet-cli-build (sdk)'
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
    $targetsText = ConvertTo-SingleQuotedList -Values $workflowTargets
    $checkCmd = "python tools/workflows/update_workflows.py --check $targetsText"
    $wfCode = Invoke-Container -Image $ToolsImageTag -Arguments @('bash','-lc',$checkCmd) -AcceptExitCodes @(0,3) -Label 'workflow-drift (tools)'
    if ($wfCode -eq 3 -and -not (Test-WorkflowDriftPending -Paths $workflowTargets)) {
      Write-Host '[docker] workflow-drift (tools) reported drift but no files changed; treating as clean.' -ForegroundColor Yellow
      $wfCode = 0
    }
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
    $targetsText = ConvertTo-SingleQuotedList -Values $workflowTargets
    $checkCmd = @"
pip install -q ruamel.yaml && \
python tools/workflows/update_workflows.py --check $targetsText
"@
    $wfCode = Invoke-Container -Image 'python:3.12-alpine' -Arguments @('sh','-lc',$checkCmd) -AcceptExitCodes @(0,3) -Label 'workflow-drift'
    if ($wfCode -eq 3 -and -not (Test-WorkflowDriftPending -Paths $workflowTargets)) {
      Write-Host '[docker] workflow-drift (fallback) reported drift but no files changed; treating as clean.' -ForegroundColor Yellow
      $wfCode = 0
    }
    if ($FailOnWorkflowDrift -and $wfCode -eq 3) {
      Write-Host 'Workflow drift detected (enforced).' -ForegroundColor Red
      exit 3
    }
  }
}

Write-Host 'Non-LabVIEW container checks completed.' -ForegroundColor Green
