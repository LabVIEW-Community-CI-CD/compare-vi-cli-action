#Requires -Version 7.0
<#
.SYNOPSIS
  Runs Docker/Desktop-backed validation checks for repo linting, workflow drift, and NI Linux review evidence.

.DESCRIPTION
  Executes the repository's non-LV tooling in containerized environments to mirror CI behaviour
  while keeping the working tree deterministic. Each check mounts the repository read/write and
  runs against the current workspace. When requested, the helper also drives the NI Linux review
  suite from the host plane against Docker Desktop/Linux so the same entrypoint can produce
  `history-report.html`, `history-summary.json`, and related GitHub Pages-ready outputs.

  Exit codes:
    - 0 : success
    - non-zero : first failing check exit code is propagated.

.PARAMETER SkipActionlint
  Skip the actionlint check.
.PARAMETER SkipMarkdown
  Skip the markdownlint check.
.PARAMETER SkipDocs
  Skip the docs link checker.
.PARAMETER SkipWorkflow
  Skip the workflow checkout contract checks.
.PARAMETER SkipDotnetCliBuild
  Skip building the CompareVI .NET CLI inside the dotnet SDK container (outputs to dist/comparevi-cli by default).
.PARAMETER PrioritySync
  Run standing-priority sync inside the tools container (requires GH_TOKEN or cached priority artifacts).
.PARAMETER NILinuxReviewSuite
  Run the hosted NI Linux smoke + VI history suite using Docker Desktop/Linux from the host plane.
.PARAMETER RequirementsVerification
  Run requirements traceability / verification inside Docker so uncovered requirement IDs can be iterated locally.
.PARAMETER NILinuxReviewSuiteResultsRoot
  Results root for NI Linux smoke + VI history outputs. Defaults to
  tests/results/docker-tools-parity/ni-linux-review-suite.
.PARAMETER RequirementsVerificationResultsRoot
  Results root for requirements traceability / verification outputs. Defaults to
  tests/results/docker-tools-parity/requirements-verification.
.PARAMETER NILinuxReviewSuiteBaseVi
  Base VI used for the NI Linux review suite smoke compare. Defaults to fixtures/vi-attr/Base.vi.
.PARAMETER NILinuxReviewSuiteHeadVi
  Head VI used for the NI Linux review suite smoke compare. Defaults to fixtures/vi-attr/Head.vi.
.PARAMETER NILinuxReviewSuiteHistoryTargetPath
  Optional single-VI history target path forwarded to tools/Invoke-NILinuxReviewSuite.ps1.
.PARAMETER NILinuxReviewSuiteHistoryBranchRef
  Optional branch ref / commit SHA used for touch-aware single-VI history review.
.PARAMETER NILinuxReviewSuiteHistoryBaselineRef
  Optional baseline ref used for touch-aware single-VI history review.
.PARAMETER NILinuxReviewSuiteHistoryMaxCommitCount
  Optional max commit scan depth for the touch-aware single-VI history review loop.
.PARAMETER NILinuxReviewSuiteHistoryReviewReceiptPath
  Optional output path for the single-VI review-loop receipt. Relative paths are resolved from the
  repository root. When omitted, tools/Invoke-NILinuxReviewSuite.ps1 writes the receipt under the
  selected NI Linux review-suite results root.
.PARAMETER PesterPath
  Optional Pester path(s) to execute inside the tools container. When provided, the host only orchestrates Docker and
  the requested Pester run happens in-container.
.PARAMETER PesterFullName
  Optional Pester FullName filter(s) forwarded to tools/Run-Pester.ps1 for targeted containerized execution.
.PARAMETER PesterIncludeIntegration
  Include Integration-tagged tests in the containerized Pester run.
.PARAMETER DockerSocketPassthrough
  Mount the host Docker socket into the tools container and forward DOCKER_HOST.
  Required when the in-container workload launches sibling Docker containers,
  such as the NILinuxCompare Pester suite.
.NOTES
  Environment variables:
    - COMPAREVI_TOOLS_IMAGE: Default image tag when -UseToolsImage is supplied without -ToolsImageTag.
#>
param(
  [switch]$SkipActionlint,
  [switch]$SkipMarkdown,
  [switch]$SkipDocs,
  [switch]$SkipWorkflow,
  [switch]$FailOnWorkflowDrift,
  [switch]$SkipDotnetCliBuild,
  [switch]$PrioritySync,
  [switch]$NILinuxReviewSuite,
  [switch]$RequirementsVerification,
  [string]$NILinuxReviewSuiteResultsRoot = 'tests/results/docker-tools-parity/ni-linux-review-suite',
  [string]$RequirementsVerificationResultsRoot = 'tests/results/docker-tools-parity/requirements-verification',
  [string]$NILinuxReviewSuiteBaseVi = 'fixtures/vi-attr/Base.vi',
  [string]$NILinuxReviewSuiteHeadVi = 'fixtures/vi-attr/Head.vi',
  [string]$NILinuxReviewSuiteHistoryTargetPath = '',
  [string]$NILinuxReviewSuiteHistoryBranchRef = '',
  [string]$NILinuxReviewSuiteHistoryBaselineRef = '',
  [int]$NILinuxReviewSuiteHistoryMaxCommitCount = 0,
  [string]$NILinuxReviewSuiteHistoryReviewReceiptPath = 'tests/results/docker-tools-parity/ni-linux-review-suite/vi-history-review-loop-receipt.json',
  [string]$ToolsImageTag,
  [switch]$UseToolsImage,
  [string[]]$PesterPath,
  [string[]]$PesterFullName,
  [string[]]$PesterTag,
  [string[]]$PesterExcludeTag,
  [switch]$PesterIncludeIntegration,
  [switch]$DockerSocketPassthrough,
  [string]$PesterResultsDir = 'tests/results/docker-pester'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)) {
  throw "Docker CLI not found. Install Docker Desktop or Docker Engine to run containerized checks."
}

function Resolve-GitHubToken {
  $envToken = $env:GH_TOKEN
  if (-not [string]::IsNullOrWhiteSpace($envToken)) { return $envToken.Trim() }

  $envToken = $env:GITHUB_TOKEN
  if (-not [string]::IsNullOrWhiteSpace($envToken)) { return $envToken.Trim() }

  $candidatePaths = [System.Collections.Generic.List[string]]::new()

  if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN_FILE)) {
    $candidatePaths.Add($env:GH_TOKEN_FILE)
  }

  if ($IsWindows) {
    $candidatePaths.Add('C:\\github_token.txt')
  }

  $userProfile = [Environment]::GetFolderPath('UserProfile')
  if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
    $candidatePaths.Add((Join-Path $userProfile '.config/github-token'))
    $candidatePaths.Add((Join-Path $userProfile '.github_token'))
  }

  $homePath = [Environment]::GetEnvironmentVariable('HOME')
  if (-not [string]::IsNullOrWhiteSpace($homePath) -and $homePath -ne $userProfile) {
    $candidatePaths.Add((Join-Path $homePath '.config/github-token'))
    $candidatePaths.Add((Join-Path $homePath '.github_token'))
  }

  foreach ($candidate in $candidatePaths) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
      $line = Get-Content -LiteralPath $candidate -ErrorAction Stop |
        Where-Object { $_ -match '\S' } |
        Select-Object -First 1
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-Verbose ("[priority] Loaded GitHub token from {0}" -f $candidate)
        return $line.Trim()
      }
    } catch {
      if ($_.Exception -isnot [System.IO.FileNotFoundException]) {
        Write-Verbose ("[priority] Failed to read token file {0}: {1}" -f $candidate, $_.Exception.Message)
      }
    }
  }

  return $null
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

function Resolve-ContainerGitArgs {
  param([string]$RepoRoot)

  $gitPointerPath = Join-Path $RepoRoot '.git'
  if (-not (Test-Path -LiteralPath $gitPointerPath -PathType Leaf)) {
    return @()
  }

  $gitDirRaw = (& git -C $RepoRoot rev-parse --git-dir 2>$null)
  $gitCommonDirRaw = (& git -C $RepoRoot rev-parse --git-common-dir 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDirRaw) -or [string]::IsNullOrWhiteSpace($gitCommonDirRaw)) {
    throw 'Unable to resolve git worktree metadata for containerized execution.'
  }

  $gitDirValue = ($gitDirRaw -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1).Trim()
  $gitCommonDirValue = ($gitCommonDirRaw -split "`r?`n" | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1).Trim()
  $gitDirPath = if ([System.IO.Path]::IsPathRooted($gitDirValue)) {
    (Resolve-Path -LiteralPath $gitDirValue).Path
  } else {
    (Resolve-Path -LiteralPath (Join-Path $RepoRoot $gitDirValue)).Path
  }
  $gitCommonDirPath = if ([System.IO.Path]::IsPathRooted($gitCommonDirValue)) {
    (Resolve-Path -LiteralPath $gitCommonDirValue).Path
  } else {
    (Resolve-Path -LiteralPath (Join-Path $RepoRoot $gitCommonDirValue)).Path
  }
  $worktreeName = Split-Path -Leaf $gitDirPath

  return @(
    '-v', ("{0}:/comparevi-git" -f (Get-DockerHostPath -Path $gitCommonDirPath)),
    '-v', ("{0}:/comparevi-git/worktrees/{1}" -f (Get-DockerHostPath -Path $gitDirPath), $worktreeName),
    '-e', ("GIT_DIR=/comparevi-git/worktrees/{0}" -f $worktreeName),
    '-e', 'GIT_WORK_TREE=/work'
  )
}

function Test-TargetsNILinuxContainerCompareSuite {
  param([string[]]$Paths)

  foreach ($path in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }

    if ([string]::Equals([System.IO.Path]::GetFileName($path), 'Run-NILinuxContainerCompare.Tests.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Resolve-DockerSocketPassthroughArgs {
  $socketPath = '/var/run/docker.sock'
  if ($IsWindows) {
    throw 'Docker socket passthrough is only supported from Linux or WSL hosts.'
  }

  if (-not (Test-Path -LiteralPath $socketPath)) {
    throw ("Docker socket '{0}' was not found. Start Docker on a Linux/WSL host before using -DockerSocketPassthrough." -f $socketPath)
  }

  $socketGroupId = $null
  try {
    $socketGroupId = (& stat -c '%g' $socketPath 2>$null | Select-Object -First 1)
  } catch {
    $socketGroupId = $null
  }
  if ($null -ne $socketGroupId) {
    $socketGroupId = [string]$socketGroupId
    $socketGroupId = $socketGroupId.Trim()
  }

  if ([string]::IsNullOrWhiteSpace($socketGroupId) -or $socketGroupId -notmatch '^\d+$') {
    throw ("Unable to resolve Docker socket group id for '{0}'." -f $socketPath)
  }

  return @(
    '-v', ("{0}:{0}" -f $socketPath),
    '--group-add', $socketGroupId,
    '-e', 'DOCKER_HOST=unix:///var/run/docker.sock'
  )
}

$hostPath = Get-DockerHostPath '.'
$volumeSpec = "${hostPath}:/work"
$commonArgs = @('--rm','-v', $volumeSpec,'-w','/work')
$commonArgs += @(Resolve-ContainerGitArgs -RepoRoot (Resolve-Path -LiteralPath '.').Path)
$forwardKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($key in @('GH_TOKEN','GITHUB_TOKEN','HTTP_PROXY','HTTPS_PROXY','NO_PROXY','http_proxy','https_proxy','no_proxy')) {
  $value = [Environment]::GetEnvironmentVariable($key)
  if (-not [string]::IsNullOrWhiteSpace($value) -and $forwardKeys.Add($key)) {
    $commonArgs += @('-e', "${key}=${value}")
  }
}
$resolvedGitHubToken = Resolve-GitHubToken
if (-not [string]::IsNullOrWhiteSpace($resolvedGitHubToken)) {
  if ($forwardKeys.Add('GH_TOKEN')) { $commonArgs += @('-e', "GH_TOKEN=$resolvedGitHubToken") }
  if ($forwardKeys.Add('GITHUB_TOKEN')) { $commonArgs += @('-e', "GITHUB_TOKEN=$resolvedGitHubToken") }
}
# Forward git SHA when available for traceability
$buildSha = $null
try { $buildSha = (git rev-parse HEAD).Trim() } catch { $buildSha = $null }
if (-not $buildSha) { $buildSha = $env:GITHUB_SHA }
if ($buildSha) { $commonArgs += @('-e', "BUILD_GIT_SHA=$buildSha") }
$workflowContractTests = @(
  'tools/priority/__tests__/workflow-checkout-contract.test.mjs',
  'tools/priority/__tests__/workflows-lint-workflow-contract.test.mjs',
  'tools/priority/__tests__/agent-review-policy-contract.test.mjs',
  'tools/priority/__tests__/validate-standard-path-contract.test.mjs'
)

function ConvertTo-PowerShellSingleQuotedLiteral {
  param([string]$Value)
  if ($null -eq $Value) { return "''" }
  return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Container {
  param(
    [string]$Image,
    [string[]]$Arguments,
    [int[]]$AcceptExitCodes = @(0),
    [string]$Label,
    [string[]]$DockerRunArguments = @()
  )
  $labelText = if ($Label) { $Label } else { $Image }
  Write-Host ("[docker] {0}" -f $labelText) -ForegroundColor Cyan
  $cmd = @('docker','run') + $commonArgs + @($DockerRunArguments) + @($Image) + $Arguments
  $displayCmd = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $cmd.Count; $i++) {
    $arg = $cmd[$i]
    if ($arg -eq '-e' -and $i + 1 -lt $cmd.Count) {
      $next = $cmd[$i + 1]
      if ($next -like 'GH_TOKEN=*' -or $next -like 'GITHUB_TOKEN=*') {
        $displayCmd.Add($arg)
        $prefix = $next.Split('=')[0]
        $displayCmd.Add("$prefix=***")
        $i++
        continue
      }
    }
    $displayCmd.Add($arg)
  }
  Write-Host ("`t" + ($displayCmd.ToArray() -join ' ')) -ForegroundColor DarkGray
  & docker run @commonArgs @DockerRunArguments $Image @Arguments
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

if ($FailOnWorkflowDrift) {
  Write-Verbose 'FailOnWorkflowDrift is deprecated; workflow checkout contract checks are enforced whenever SkipWorkflow is not set.'
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
    $publishLines = @(
      'rm -rf src/CompareVi.Shared/obj src/CompareVi.Tools.Cli/obj || true',
      'BASE_VERSION=$(grep -oPm1 "(?<=<Version>)[^<]+" Directory.Build.props || echo "0.0.0")',
      'if [ -n "$BUILD_GIT_SHA" ]; then',
      '  IV="${BASE_VERSION}+${BUILD_GIT_SHA}"',
      'else',
      '  IV="${BASE_VERSION}+local"',
      'fi',
      ('dotnet publish "' + $projectPath + '" -c Release -nologo -o "' + $cliOutput + '" -p:UseAppHost=false -p:InformationalVersion="$IV"')
    )
    $publishCommand = ($publishLines -join "`n")
    # Build with official .NET SDK container to avoid file-permission quirks in tools image
    Invoke-Container -Image 'mcr.microsoft.com/dotnet/sdk:8.0' `
      -Arguments @('bash','-lc',$publishCommand) `
      -Label 'dotnet-cli-build (sdk)'
  }
}

if ($UseToolsImage -and -not $ToolsImageTag -and $env:COMPAREVI_TOOLS_IMAGE) {
  $ToolsImageTag = $env:COMPAREVI_TOOLS_IMAGE
}

$repoRootResolved = (Resolve-Path -LiteralPath '.').Path
$pesterRequested = $PSBoundParameters.ContainsKey('PesterPath') -or
  $PSBoundParameters.ContainsKey('PesterFullName') -or
  $PSBoundParameters.ContainsKey('PesterTag') -or
  $PSBoundParameters.ContainsKey('PesterExcludeTag') -or
  $PSBoundParameters.ContainsKey('PesterIncludeIntegration') -or
  $PSBoundParameters.ContainsKey('PesterResultsDir')

if ($pesterRequested -and -not $UseToolsImage) {
  $UseToolsImage = $true
}

if ($UseToolsImage -and -not $ToolsImageTag) {
  $ToolsImageTag = 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest'
}

$requiresDockerSocketPassthrough = $false
if ($UseToolsImage -and $pesterRequested) {
  $requiresDockerSocketPassthrough = $DockerSocketPassthrough -or (Test-TargetsNILinuxContainerCompareSuite -Paths $PesterPath)
}
$dockerSocketPassthroughArgs = @()
if ($requiresDockerSocketPassthrough) {
  $dockerSocketPassthroughArgs = Resolve-DockerSocketPassthroughArgs
  Write-Host '[docker] Enabling Docker socket passthrough for tools-container Pester execution.' -ForegroundColor Cyan
}

if ($UseToolsImage -and $ToolsImageTag) {
  if (-not $SkipActionlint) {
    Invoke-Container -Image $ToolsImageTag -Arguments @('actionlint','-color') -Label 'actionlint (tools)'
  }
  if (-not $SkipMarkdown) {
    $cmd = 'if ! command -v git >/dev/null 2>&1; then echo "git is required for markdownlint discovery" >&2; exit 1; fi; git config --global --add safe.directory /work >/dev/null 2>&1 || true; node tools/npm/run-script.mjs lint:md'
    Invoke-Container -Image $ToolsImageTag -Arguments @('bash','-lc',$cmd) -Label 'markdownlint (tools)'
  }
  if (-not $SkipDocs) {
    Invoke-Container -Image $ToolsImageTag -Arguments @('pwsh','-NoLogo','-NoProfile','-File','tools/Check-DocsLinks.ps1','-Path','docs') -Label 'docs-links (tools)'
  }
  if (-not $SkipWorkflow) {
    $testArgs = @('--test') + $workflowContractTests
    Invoke-Container -Image $ToolsImageTag -Arguments (@('node') + $testArgs) -Label 'workflow-contracts (tools)' | Out-Null
  }
} else {
  if (-not $SkipActionlint) {
    Invoke-Container -Image 'rhysd/actionlint:1.7.7' -Arguments @('-color') -Label 'actionlint'
  }
  if (-not $SkipMarkdown) {
    $cmd = 'if ! command -v git >/dev/null 2>&1; then echo "git is required for markdownlint discovery" >&2; exit 1; fi; git config --global --add safe.directory /work >/dev/null 2>&1 || true; node tools/npm/run-script.mjs lint:md'
    Invoke-Container -Image 'node:20' -Arguments @('bash','-lc',$cmd) -Label 'markdownlint'
  }
  if (-not $SkipDocs) {
    Invoke-Container -Image 'mcr.microsoft.com/powershell:7.4-debian-12' -Arguments @('pwsh','-NoLogo','-NoProfile','-File','tools/Check-DocsLinks.ps1','-Path','docs') -Label 'docs-links'
  }
  if (-not $SkipWorkflow) {
    $testArgs = @('--test') + $workflowContractTests
    Invoke-Container -Image 'node:20' -Arguments (@('node') + $testArgs) -Label 'workflow-contracts' | Out-Null
  }
}

if ($NILinuxReviewSuite) {
  $reviewSuiteScriptPath = Join-Path $repoRootResolved 'tools' 'Invoke-NILinuxReviewSuite.ps1'
  if (-not (Test-Path -LiteralPath $reviewSuiteScriptPath -PathType Leaf)) {
    throw ("NI Linux review suite helper not found: {0}" -f $reviewSuiteScriptPath)
  }

  $resultsRootResolved = [System.IO.Path]::GetFullPath((Join-Path $repoRootResolved $NILinuxReviewSuiteResultsRoot))
  $reviewSuiteSummaryHtmlPath = Join-Path $resultsRootResolved 'review-suite-summary.html'
  $reviewSuiteSummaryJsonPath = Join-Path $resultsRootResolved 'review-suite-summary.json'
  $historyMarkdownPath = Join-Path $resultsRootResolved 'vi-history-report/results/history-report.md'
  $historyHtmlPath = Join-Path $resultsRootResolved 'vi-history-report/results/history-report.html'
  $historySummaryPath = Join-Path $resultsRootResolved 'vi-history-report/results/history-summary.json'
  $historyReviewReceiptPath = Join-Path $resultsRootResolved 'vi-history-review-loop-receipt.json'
  $historyInspectionHtmlPath = Join-Path $resultsRootResolved 'vi-history-report/results/history-suite-inspection.html'

  Write-Host '[docker] ni-linux-review-suite (host)' -ForegroundColor Cyan
  Write-Host ("`tresultsRoot=" + [System.IO.Path]::GetRelativePath($repoRootResolved, $resultsRootResolved).Replace('\', '/')) -ForegroundColor DarkGray
  $reviewSuiteParams = @{
    BaseVi = $NILinuxReviewSuiteBaseVi
    HeadVi = $NILinuxReviewSuiteHeadVi
    ResultsRoot = $NILinuxReviewSuiteResultsRoot
  }
  if (
    $PSBoundParameters.ContainsKey('NILinuxReviewSuiteHistoryReviewReceiptPath') -and
    -not [string]::IsNullOrWhiteSpace($NILinuxReviewSuiteHistoryReviewReceiptPath)
  ) {
    $reviewSuiteParams.HistoryReviewReceiptPath = $NILinuxReviewSuiteHistoryReviewReceiptPath
    $historyReviewReceiptPath = [System.IO.Path]::GetFullPath((Join-Path $repoRootResolved $NILinuxReviewSuiteHistoryReviewReceiptPath))
  }
  if (-not [string]::IsNullOrWhiteSpace($NILinuxReviewSuiteHistoryTargetPath)) {
    $reviewSuiteParams.HistoryTargetPath = $NILinuxReviewSuiteHistoryTargetPath
  }
  if (-not [string]::IsNullOrWhiteSpace($NILinuxReviewSuiteHistoryBranchRef)) {
    $reviewSuiteParams.HistoryBranchRef = $NILinuxReviewSuiteHistoryBranchRef
  }
  if (-not [string]::IsNullOrWhiteSpace($NILinuxReviewSuiteHistoryBaselineRef)) {
    $reviewSuiteParams.HistoryBaselineRef = $NILinuxReviewSuiteHistoryBaselineRef
  }
  if ($NILinuxReviewSuiteHistoryMaxCommitCount -gt 0) {
    $reviewSuiteParams.HistoryMaxCommitCount = $NILinuxReviewSuiteHistoryMaxCommitCount
  }
  Push-Location $repoRootResolved
  try {
    & $reviewSuiteScriptPath @reviewSuiteParams
    $reviewSuiteExit = $LASTEXITCODE
    if ($reviewSuiteExit -ne 0) {
      throw ("NI Linux review suite exited with code {0}." -f $reviewSuiteExit)
    }
  } finally {
    Pop-Location | Out-Null
  }

  foreach ($artifactPath in @(
      $reviewSuiteSummaryHtmlPath,
      $reviewSuiteSummaryJsonPath,
      $historyMarkdownPath,
      $historyHtmlPath,
      $historySummaryPath,
      $historyReviewReceiptPath,
      $historyInspectionHtmlPath
    )) {
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      throw ("NI Linux review suite missing expected artifact: {0}" -f $artifactPath)
    }
  }

  Write-Host ("[docker] ni-linux-review-suite OK (summary={0}; history={1}; facade={2})" -f
      ([System.IO.Path]::GetRelativePath($repoRootResolved, $reviewSuiteSummaryHtmlPath).Replace('\', '/')),
      ([System.IO.Path]::GetRelativePath($repoRootResolved, $historyHtmlPath).Replace('\', '/')),
      ([System.IO.Path]::GetRelativePath($repoRootResolved, $historySummaryPath).Replace('\', '/'))) -ForegroundColor Green
}

if ($RequirementsVerification) {
  $requirementsResultsRootResolved = [System.IO.Path]::GetFullPath((Join-Path $repoRootResolved $RequirementsVerificationResultsRoot))
  $requirementsSummaryPath = Join-Path $requirementsResultsRootResolved 'verification-summary.json'
  $traceMatrixJsonPath = Join-Path $requirementsResultsRootResolved 'trace-matrix.json'
  $traceMatrixHtmlPath = Join-Path $requirementsResultsRootResolved 'trace-matrix.html'
  $requirementsImage = if ($UseToolsImage -and $ToolsImageTag) { $ToolsImageTag } else { 'mcr.microsoft.com/powershell:7.4-debian-12' }
  $requirementsCommand = @(
    '$ErrorActionPreference = ''Stop''',
    'if (Get-Command git -ErrorAction SilentlyContinue) { try { git config --global --add safe.directory /work | Out-Null } catch { Write-Warning ''Unable to mark /work as a safe git directory; continuing with requirements verification.'' } }',
    ('& ./tools/Verify-RequirementsGate.ps1 -TestsPath ''tests'' -ResultsRoot ''tests/results'' -OutDir {0}' -f
      (ConvertTo-PowerShellSingleQuotedLiteral -Value $RequirementsVerificationResultsRoot)),
    'exit $LASTEXITCODE'
  ) -join [Environment]::NewLine

  Invoke-Container -Image $requirementsImage `
    -Arguments @('pwsh', '-NoLogo', '-NoProfile', '-Command', $requirementsCommand) `
    -Label 'requirements-verification' | Out-Null

  foreach ($artifactPath in @(
      $requirementsSummaryPath,
      $traceMatrixJsonPath,
      $traceMatrixHtmlPath
    )) {
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      throw ("Requirements verification missing expected artifact: {0}" -f $artifactPath)
    }
  }

  Write-Host ("[docker] requirements-verification OK (summary={0}; trace={1})" -f
      ([System.IO.Path]::GetRelativePath($repoRootResolved, $requirementsSummaryPath).Replace('\', '/')),
      ([System.IO.Path]::GetRelativePath($repoRootResolved, $traceMatrixJsonPath).Replace('\', '/'))) -ForegroundColor Green
}

if ($PrioritySync) {
  $syncScript = 'git config --global --add safe.directory /work >/dev/null 2>&1 || true; node tools/npm/run-script.mjs priority:sync:strict'
  $ran = $false
  if ($UseToolsImage -and $ToolsImageTag) {
    $imageCheck = & docker image inspect $ToolsImageTag 2>$null
    if ($LASTEXITCODE -eq 0) {
      Invoke-Container -Image $ToolsImageTag -Arguments @('bash','-lc',$syncScript) -Label 'priority-sync (tools)' | Out-Null
      $ran = $true
    } else {
      Write-Warning "Tools image '$ToolsImageTag' not found; falling back to node:20 for priority sync." 
    }
  }
  if (-not $ran) {
    Invoke-Container -Image 'node:20' -Arguments @('bash','-lc',$syncScript) -Label 'priority-sync' | Out-Null
  }
}

if ($pesterRequested) {
  $pesterScriptLines = New-Object System.Collections.Generic.List[string]
  $pesterScriptLines.Add('$ErrorActionPreference = ''Stop''')
  $pesterScriptLines.Add('git config --global --add safe.directory /work | Out-Null')
  $pesterScriptLines.Add('$params = @{')
  $pesterScriptLines.Add(("  ResultsDir = {0}" -f (ConvertTo-PowerShellSingleQuotedLiteral -Value $PesterResultsDir)))
  if ($PesterIncludeIntegration) {
    $pesterScriptLines.Add('  IncludeIntegration = $true')
  }
  if ($PesterPath) {
    $pathEntries = @($PesterPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$_) })
    if ($pathEntries.Count -gt 0) {
      $pesterScriptLines.Add(("  Path = @({0})" -f ($pathEntries -join ', ')))
    }
  }
  if ($PesterFullName) {
    $fullNameEntries = @($PesterFullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$_) })
    if ($fullNameEntries.Count -gt 0) {
      $pesterScriptLines.Add(("  FullName = @({0})" -f ($fullNameEntries -join ', ')))
    }
  }
  if ($PesterTag) {
    $tagEntries = @($PesterTag | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$_) })
    if ($tagEntries.Count -gt 0) {
      $pesterScriptLines.Add(("  Tag = @({0})" -f ($tagEntries -join ', ')))
    }
  }
  if ($PesterExcludeTag) {
    $excludeTagEntries = @($PesterExcludeTag | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$_) })
    if ($excludeTagEntries.Count -gt 0) {
      $pesterScriptLines.Add(("  ExcludeTag = @({0})" -f ($excludeTagEntries -join ', ')))
    }
  }
  $pesterScriptLines.Add('}')
  $pesterScriptLines.Add('& ./tools/Run-Pester.ps1 @params')
  $pesterScriptLines.Add('exit $LASTEXITCODE')
  $pesterScript = $pesterScriptLines -join [Environment]::NewLine

  Invoke-Container -Image $ToolsImageTag `
    -Arguments @('pwsh', '-NoLogo', '-NoProfile', '-Command', $pesterScript) `
    -Label 'pester (tools)' `
    -DockerRunArguments $dockerSocketPassthroughArgs | Out-Null
}

Write-Host 'Non-LabVIEW container checks completed.' -ForegroundColor Green
