#Requires -Version 7.0
<#
.SYNOPSIS
  Local pre-push checks: run actionlint against workflows.
.DESCRIPTION
  Ensures a valid actionlint binary is used per-OS and runs it against .github/workflows.
  On Windows, explicitly prefers bin/actionlint.exe to avoid invoking the non-Windows binary.
.PARAMETER ActionlintVersion
  Optional version to install if missing (default: 1.7.7). Only used when auto-installing.
.PARAMETER InstallIfMissing
  Attempt to install actionlint if not found (default: true).
#>
param(
  [string]$ActionlintVersion = '1.7.7',
  [bool]$InstallIfMissing = $true,
  [switch]$SkipNiImageFlagScenarios,
  [switch]$SkipLegacyFixtureChecks,
  [switch]$SkipPSScriptAnalyzer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1') -Force

$localCollabPhase = [string]($env:LOCAL_COLLAB_PHASE ?? '')
if ($env:LOCAL_COLLAB_ORCHESTRATED -match '^(1|true|yes|on)$') {
  Write-Host ("[pre-push] local collaboration orchestrator active{0}" -f $(if ($localCollabPhase) { " phase=$localCollabPhase" } else { '' })) -ForegroundColor DarkGray
}

function Write-Info([string]$msg){ Write-Host $msg -ForegroundColor DarkGray }

function Resolve-ContainerMountedHostPath {
  param(
    [string]$Path,
    [object[]]$Mounts
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $Path
  }

  if (Test-Path -LiteralPath $Path) {
    return (Resolve-Path -LiteralPath $Path).Path
  }

  $normalizedCandidate = $Path.Replace('\', '/')
  foreach ($mount in @($Mounts)) {
    if ($null -eq $mount) {
      continue
    }
    $hostPath = if ($mount.PSObject.Properties['hostPath']) { [string]$mount.hostPath } else { '' }
    $containerPath = if ($mount.PSObject.Properties['containerPath']) { [string]$mount.containerPath } else { '' }
    if ([string]::IsNullOrWhiteSpace($hostPath) -or [string]::IsNullOrWhiteSpace($containerPath)) {
      continue
    }

    $normalizedContainerPath = $containerPath.Trim().TrimEnd('/').Replace('\', '/')
    if ($normalizedCandidate -eq $normalizedContainerPath) {
      return $hostPath
    }

    $prefix = '{0}/' -f $normalizedContainerPath
    if ($normalizedCandidate.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
      $relativePath = $normalizedCandidate.Substring($prefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
      return (Join-Path $hostPath $relativePath)
    }
  }

  return $Path
}

function Get-LogTailText {
  param(
    [string]$Path,
    [int]$TailLines = 20
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ''
  }

  $lines = @(Get-Content -LiteralPath $Path -Tail $TailLines -ErrorAction SilentlyContinue)
  if ($lines.Count -eq 0) {
    return ''
  }

  return (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Get-RepoRoot {
  $here = Split-Path -Parent $PSCommandPath
  return (Resolve-Path -LiteralPath (Join-Path $here '..'))
}

function Get-ActionlintPath([string]$repoRoot){ return Resolve-ActionlintPath }

function Install-Actionlint([string]$repoRoot,[string]$version){
  $bin = Join-Path $repoRoot 'bin'
  if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }

  if ($IsWindows) {
    # Determine arch
    $arch = ($env:PROCESSOR_ARCHITECTURE ?? 'AMD64').ToUpperInvariant()
    $asset = if ($arch -like '*ARM64*') { "actionlint_${version}_windows_arm64.zip" } else { "actionlint_${version}_windows_amd64.zip" }
    $url = "https://github.com/rhysd/actionlint/releases/download/v${version}/${asset}"
    $zip = Join-Path $bin 'actionlint.zip'
    Write-Info "Downloading actionlint ${version} (${asset})..."
    try {
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $bin, $true)
    } finally { if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } }
  } else {
    # Try vendored downloader if available
  $dlCandidates = @(
    (Join-Path -Path $bin -ChildPath 'dl-actionlint.sh'),
    (Join-Path -Path $repoRoot -ChildPath 'tools/dl-actionlint.sh')
  )
  $dl = $dlCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($dl) {
    Write-Info "Installing actionlint ${version} via dl-actionlint.sh (${dl})..."
    & bash $dl $version $bin
  } else {
      # Generic fallback using upstream script
      Write-Info "Installing actionlint ${version} via upstream script..."
      $script = "https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash"
      bash -lc "curl -sSL ${script} | bash -s -- ${version} ${bin}"
    }
  }
}

function Invoke-NodeTestSanitized {
  param(
    [string[]]$Args
  )

  $output = & node @Args 2>&1
  $exitCode = $LASTEXITCODE
  if ($output) {
    $normalized = $output | ForEach-Object {
      $_ -replace 'duration_ms: \d+(?:\.\d+)?', 'duration_ms: <sanitized>' -replace '# duration_ms \d+(?:\.\d+)?', '# duration_ms <sanitized>'
    }
    $normalized | ForEach-Object { Write-Host $_ }
  }
  return $exitCode
}

function Invoke-Actionlint([string]$repoRoot){
  $exe = Get-ActionlintPath -repoRoot $repoRoot
  if (-not $exe) {
    if ($InstallIfMissing) {
      Install-Actionlint -repoRoot $repoRoot -version $ActionlintVersion | Out-Null
      $exe = Get-ActionlintPath -repoRoot $repoRoot
    }
  }
  if (-not $exe) { throw "actionlint not found after attempted install under '${repoRoot}/bin'" }

  # Explicitly resolve .exe on Windows to avoid picking the non-Windows binary
  if ($IsWindows -and (Split-Path -Leaf $exe) -eq 'actionlint') {
    $winExe = Join-Path (Split-Path -Parent $exe) 'actionlint.exe'
    if (Test-Path -LiteralPath $winExe -PathType Leaf) { $exe = $winExe }
  }

  Write-Host "[pre-push] Running: $exe -color" -ForegroundColor Cyan
  Push-Location $repoRoot
  try {
    & $exe -color
    return [int]$LASTEXITCODE
  } finally {
    Pop-Location | Out-Null
  }
}

function Get-ChangedPowerShellPaths([string]$repoRoot) {
  $patterns = @('*.ps1', '*.psm1', '*.psd1')
  $ranges = @('upstream/develop...HEAD', 'origin/develop...HEAD', 'HEAD~1..HEAD')
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $files = New-Object System.Collections.Generic.List[string]

  foreach ($range in $ranges) {
    $diffArgs = @('-C', $repoRoot, 'diff', '--name-only', '--diff-filter=ACMRT', $range, '--') + $patterns
    $raw = & git @diffArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
      continue
    }
    foreach ($entry in @($raw | Where-Object { $_ -and $_.Trim() })) {
      $relative = $entry.Trim()
      if (-not $seen.Add($relative)) {
        continue
      }
      $absolute = Join-Path $repoRoot $relative
      if (Test-Path -LiteralPath $absolute -PathType Leaf) {
        $files.Add($absolute)
      }
    }
    if ($files.Count -gt 0) {
      break
    }
  }

  return $files.ToArray()
}

function Invoke-PSScriptAnalyzerGate([string]$repoRoot) {
  $skipAnalyzer = $SkipPSScriptAnalyzer -or ($env:PREPUSH_SKIP_PSSCRIPTANALYZER -match '^(1|true|yes|on)$')
  if ($skipAnalyzer) {
    Write-Host '[pre-push] Skipping PSScriptAnalyzer by request' -ForegroundColor Yellow
    return
  }

  if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host '[pre-push] PSScriptAnalyzer not installed; skipping analyzer gate' -ForegroundColor Yellow
    return
  }

  $paths = @(Get-ChangedPowerShellPaths -repoRoot $repoRoot)
  if ($paths.Count -eq 0) {
    Write-Host '[pre-push] No changed PowerShell files detected for analyzer gate' -ForegroundColor DarkGray
    return
  }

  Import-Module PSScriptAnalyzer -ErrorAction Stop | Out-Null
  Write-Host ("[pre-push] Running PSScriptAnalyzer on {0} changed file(s)" -f $paths.Count) -ForegroundColor Cyan
  $issues = @()
  foreach ($path in $paths) {
    $issues += Invoke-ScriptAnalyzer -Path $path -Severity Error,Warning -ErrorAction Stop
  }

  if ($issues.Count -gt 0) {
    $issues | ForEach-Object {
      Write-Host ("[pre-push][pssa] {0}:{1} {2} ({3})" -f $_.ScriptPath, $_.Line, $_.Message, $_.RuleName) -ForegroundColor Red
    }
    throw ("PSScriptAnalyzer detected {0} issue(s)." -f $issues.Count)
  }

  Write-Host '[pre-push] PSScriptAnalyzer gate OK' -ForegroundColor Green
}

function Invoke-WorkspaceHealthGate([string]$repoRoot){
  $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'check-workspace-health.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw ("workspace health gate script not found: {0}" -f $scriptPath)
  }

  $reportPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'health' 'pre-push-workspace-health.json'
  Write-Host '[pre-push] Verifying workspace health gate' -ForegroundColor Cyan
  & node $scriptPath `
    --repo-root $repoRoot `
    --report $reportPath `
    --lease-mode optional
  if ($LASTEXITCODE -ne 0) {
    throw ("workspace health gate failed (exit={0}). See {1}" -f $LASTEXITCODE, $reportPath)
  }
  Write-Host '[pre-push] workspace health gate OK' -ForegroundColor Green
}

function Invoke-SafeGitReliabilitySummary([string]$repoRoot){
  $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'summarize-safe-git-telemetry.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw ("safe-git reliability summary script not found: {0}" -f $scriptPath)
  }

  $inputPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'reliability' 'safe-git-events.jsonl'
  $outputPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'reliability' 'safe-git-trend-summary.json'
  Write-Host '[pre-push] Summarizing safe-git reliability telemetry' -ForegroundColor Cyan
  $args = @(
    $scriptPath,
    '--input', $inputPath,
    '--output', $outputPath
  )
  if ($env:GITHUB_STEP_SUMMARY) {
    $args += @('--step-summary', $env:GITHUB_STEP_SUMMARY)
  }
  & node @args
  if ($LASTEXITCODE -ne 0) {
    throw ("safe-git reliability summary failed (exit={0})." -f $LASTEXITCODE)
  }
  Write-Host '[pre-push] safe-git reliability summary OK' -ForegroundColor Green
}

function Invoke-WatcherTelemetrySchemaGate([string]$repoRoot) {
  $runScriptPath = Join-Path $repoRoot 'tools' 'npm' 'run-script.mjs'
  if (-not (Test-Path -LiteralPath $runScriptPath -PathType Leaf)) {
    throw ("sanitized npm wrapper not found: {0}" -f $runScriptPath)
  }

  Write-Host '[pre-push] Validating watcher telemetry schema' -ForegroundColor Cyan
  Push-Location $repoRoot
  try {
    & node $runScriptPath 'schema:watcher:validate'
    if ($LASTEXITCODE -ne 0) {
      throw ("watcher telemetry schema validation failed (exit={0})." -f $LASTEXITCODE)
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] watcher telemetry schema OK' -ForegroundColor Green
}

function Write-PrePushNIKnownFlagIncidentEvent {
  param(
    [string]$repoRoot,
    [string]$errorMessage,
    [string]$scenarioName,
    [string]$scenarioDir,
    [string]$capturePath,
    [string]$expectedImage,
    [string]$containerLabVIEWPath,
    [string[]]$scenarioFlags,
    [string]$reportPath,
    [string]$runtimeSnapshotPath
  )

  $eventIngestScript = Join-Path $repoRoot 'tools' 'priority' 'event-ingest.mjs'
  if (-not (Test-Path -LiteralPath $eventIngestScript -PathType Leaf)) {
    Write-Warning ("[pre-push] event-ingest script missing; cannot emit NI known-flag incident event: {0}" -f $eventIngestScript)
    return $null
  }

  $canaryDir = Join-Path $repoRoot 'tests' 'results' '_agent' 'canary'
  New-Item -ItemType Directory -Path $canaryDir -Force | Out-Null
  $inputPath = Join-Path $canaryDir 'pre-push-ni-known-flag-incident-input.json'
  $eventReportPath = Join-Path $canaryDir 'pre-push-ni-known-flag-incident-event.json'
  $repository = if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    'local/compare-vi-cli-action'
  } else {
    $env:GITHUB_REPOSITORY
  }

  $branchName = $null
  $sha = $null
  try {
    $branchRaw = & git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branchRaw) {
      $branchName = ($branchRaw | Select-Object -First 1).Trim()
      if ($branchName -eq 'HEAD') {
        $branchName = $null
      }
    }
  } catch {}
  try {
    $shaRaw = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $shaRaw) {
      $sha = ($shaRaw | Select-Object -First 1).Trim()
    }
  } catch {}

  $payload = [ordered]@{
    class = 'pre-push-ni-known-flag-failure'
    severity = 'high'
    source = 'pre-push-ni-known-flag'
    repository = $repository
    branch = $branchName
    sha = $sha
    summary = $errorMessage
    occurredAt = (Get-Date).ToUniversalTime().ToString('o')
    labels = @('ci', 'canary')
    metadata = [ordered]@{
      scenarioFamily = 'vi-comparison-report-flags'
      scenarioGroup = $scenarioName
      scenario = $scenarioName
      expectedImage = $expectedImage
      containerLabVIEWPath = $containerLabVIEWPath
      flags = @($scenarioFlags)
      scenarioDir = $scenarioDir
      compareReportPath = $reportPath
      capturePath = $capturePath
      runtimeSnapshotPath = $runtimeSnapshotPath
      captureExists = [bool](Test-Path -LiteralPath $capturePath -PathType Leaf)
      reportExists = [bool](Test-Path -LiteralPath $reportPath -PathType Leaf)
      runtimeSnapshotExists = [bool](Test-Path -LiteralPath $runtimeSnapshotPath -PathType Leaf)
    }
  }

  $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $inputPath -Encoding utf8
  & node $eventIngestScript `
    --source-type incident-event `
    --input $inputPath `
    --report $eventReportPath
  if ($LASTEXITCODE -ne 0) {
    Write-Warning ("[pre-push] NI known-flag incident normalization failed (exit={0})." -f $LASTEXITCODE)
    return $null
  }

  return $eventReportPath
}

$root = (Get-RepoRoot).Path
Invoke-WorkspaceHealthGate -repoRoot $root
$guardScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Assert-NoAmbiguousRemoteRefs.ps1'

Push-Location $root
try {
  Write-Host '[pre-push] Verifying remote refs are unambiguous' -ForegroundColor Cyan
  & $guardScript
  Write-Host '[pre-push] remote references OK' -ForegroundColor Green
} finally {
  Pop-Location | Out-Null
}

$code = Invoke-Actionlint -repoRoot $root
if ($code -ne 0) {
  Write-Error "actionlint reported issues (exit=$code)."
  exit $code
}
Write-Host '[pre-push] actionlint OK' -ForegroundColor Green
Invoke-PSScriptAnalyzerGate -repoRoot $root

Write-Host '[pre-push] Validating safe PR watch task contract' -ForegroundColor Cyan
$safeWatchContractExit = Invoke-NodeTestSanitized -Args @('--test','tools/priority/__tests__/safe-watch-task-contract.test.mjs')
if ($safeWatchContractExit -ne 0) {
  throw "safe-watch task contract validation failed (exit=$safeWatchContractExit)."
}
Write-Host '[pre-push] safe-watch task contract OK' -ForegroundColor Green
Invoke-WatcherTelemetrySchemaGate -repoRoot $root

$verificationContractScript = Join-Path $root 'tools' 'Assert-RequirementsVerificationCheckContract.ps1'
if (Test-Path -LiteralPath $verificationContractScript -PathType Leaf) {
  Write-Host '[pre-push] Verifying requirements-verification check naming contract' -ForegroundColor Cyan
  Push-Location $root
  try {
    pwsh -NoLogo -NonInteractive -NoProfile -File $verificationContractScript
    if ($LASTEXITCODE -ne 0) {
      throw "Assert-RequirementsVerificationCheckContract.ps1 failed (exit=$LASTEXITCODE)."
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] requirements-verification check contract OK' -ForegroundColor Green
}

$policyGuardContractScript = Join-Path $root 'tools' 'Assert-PolicyGuardCheckContract.ps1'
if (Test-Path -LiteralPath $policyGuardContractScript -PathType Leaf) {
  Write-Host '[pre-push] Verifying policy-guard check naming contract' -ForegroundColor Cyan
  Push-Location $root
  try {
    pwsh -NoLogo -NonInteractive -NoProfile -File $policyGuardContractScript
    if ($LASTEXITCODE -ne 0) {
      throw "Assert-PolicyGuardCheckContract.ps1 failed (exit=$LASTEXITCODE)."
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] policy-guard check contract OK' -ForegroundColor Green
}

$commitIntegrityContractScript = Join-Path $root 'tools' 'Assert-CommitIntegrityContract.ps1'
if (Test-Path -LiteralPath $commitIntegrityContractScript -PathType Leaf) {
  Write-Host '[pre-push] Verifying commit-integrity contract' -ForegroundColor Cyan
  Push-Location $root
  try {
    pwsh -NoLogo -NonInteractive -NoProfile -File $commitIntegrityContractScript
    if ($LASTEXITCODE -ne 0) {
      throw "Assert-CommitIntegrityContract.ps1 failed (exit=$LASTEXITCODE)."
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] commit-integrity contract OK' -ForegroundColor Green
}

Invoke-SafeGitReliabilitySummary -repoRoot $root

$skipNiImageChecks = $SkipNiImageFlagScenarios `
  -or $SkipLegacyFixtureChecks `
  -or ($env:PREPUSH_SKIP_NI_IMAGE_FLAG_SCENARIOS -match '^(1|true|yes|on)$') `
  -or ($env:PREPUSH_SKIP_LEGACY_FIXTURE_CHECKS -match '^(1|true|yes|on)$') `
  -or ($env:PREPUSH_SKIP_ICON_EDITOR_FIXTURE_CHECKS -match '^(1|true|yes|on)$')
if ($skipNiImageChecks) {
  Write-Host '[pre-push] Skipping VI Comparison Report flag combination scenarios by request' -ForegroundColor Yellow
  return
}

$niCompareScript = Join-Path $root 'tools' 'Run-NILinuxContainerCompare.ps1'
if (-not (Test-Path -LiteralPath $niCompareScript -PathType Leaf)) {
  throw ("NI image compare script not found: {0}" -f $niCompareScript)
}
$baseVi = Join-Path $root 'VI1.vi'
$headVi = Join-Path $root 'VI2.vi'
if (-not (Test-Path -LiteralPath $baseVi -PathType Leaf)) {
  throw ("Base VI not found for NI image known-flag scenario: {0}" -f $baseVi)
}
if (-not (Test-Path -LiteralPath $headVi -PathType Leaf)) {
  throw ("Head VI not found for NI image known-flag scenario: {0}" -f $headVi)
}

$expectedImage = 'nationalinstruments/labview:2026q1-linux'
$containerLabVIEWPath = if ([string]::IsNullOrWhiteSpace($env:NI_LINUX_LABVIEW_PATH)) {
  '/usr/local/natinst/LabVIEW-2026-64/labview'
} else {
  $env:NI_LINUX_LABVIEW_PATH.Trim()
}
$singleContainerBootstrapScript = Join-Path $root 'tools' 'NILinux-FlagMatrixBootstrap.sh'
if (-not (Test-Path -LiteralPath $singleContainerBootstrapScript -PathType Leaf)) {
  throw ("Single-container flag matrix bootstrap script not found: {0}" -f $singleContainerBootstrapScript)
}
$viHistoryBootstrapScript = Join-Path $root 'tools' 'NILinux-VIHistorySuiteBootstrap.sh'
if (-not (Test-Path -LiteralPath $viHistoryBootstrapScript -PathType Leaf)) {
  throw ("VI history bootstrap script not found: {0}" -f $viHistoryBootstrapScript)
}
$baseFlagOptions = @(
  [ordered]@{ label = 'noattr'; flag = '-noattr' },
  [ordered]@{ label = 'nofppos'; flag = '-nofppos' },
  [ordered]@{ label = 'nobdcosm'; flag = '-nobdcosm' }
)
$knownFlagScenarioBuffer = New-Object System.Collections.Generic.List[object]
for ($mask = 0; $mask -lt (1 -shl $baseFlagOptions.Count); $mask++) {
  $scenarioFlags = @()
  $scenarioLabels = @()
  $selectedIndices = @()
  for ($i = 0; $i -lt $baseFlagOptions.Count; $i++) {
    if (($mask -band (1 -shl $i)) -ne 0) {
      $scenarioFlags += [string]$baseFlagOptions[$i].flag
      $scenarioLabels += [string]$baseFlagOptions[$i].label
      $selectedIndices += $i
    }
  }

  $knownFlagScenarioBuffer.Add([pscustomobject]@{
    name = if ($scenarioLabels.Count -eq 0) { 'baseline' } else { [string]::Join('__', $scenarioLabels) }
    flags = @($scenarioFlags)
    requestedFlagsLabel = if ($scenarioFlags.Count -eq 0) { '(none)' } else { [string]::Join(', ', $scenarioFlags) }
    orderKey = if ($selectedIndices.Count -eq 0) { 'none' } else { [string]::Join('-', @($selectedIndices | ForEach-Object { '{0:d2}' -f $_ })) }
  }) | Out-Null
}
$knownFlagScenarios = @($knownFlagScenarioBuffer | Sort-Object @{ Expression = { $_.flags.Count } }, @{ Expression = { $_.orderKey } })
$scenarioRoot = Join-Path $root 'tests' 'results' '_agent' 'pre-push-ni-image'
New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
$activeScenarioName = ''
$activeScenarioFlags = @()
$scenarioDir = $scenarioRoot
$reportPath = Join-Path $scenarioDir 'compare-report.html'
$runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
$capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'
$scenarioResults = New-Object System.Collections.Generic.List[object]

try {
  Write-Host '[pre-push] Running VI Comparison Report flag combination scenarios (real container compare)' -ForegroundColor Cyan
  foreach ($scenario in $knownFlagScenarios) {
    $activeScenarioName = [string]$scenario.name
    $activeScenarioFlags = @($scenario.flags | ForEach-Object { [string]$_ })
    $scenarioDir = Join-Path $scenarioRoot $activeScenarioName
    New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
    $reportPath = Join-Path $scenarioDir 'compare-report.html'
    $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
    $capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'

    Write-Host ("[pre-push] Running NI image flag scenario '{0}' requestedFlags={1}" -f $activeScenarioName, [string]$scenario.requestedFlagsLabel) -ForegroundColor Cyan
    Push-Location $root
    try {
      & $niCompareScript `
        -BaseVi $baseVi `
        -HeadVi $headVi `
        -Image $expectedImage `
        -ReportPath $reportPath `
        -LabVIEWPath $containerLabVIEWPath `
        -ContainerNameLabel $activeScenarioName `
        -Flags $activeScenarioFlags `
        -TimeoutSeconds 240 `
        -HeartbeatSeconds 15 `
        -AutoRepairRuntime:$true `
        -RuntimeEngineReadyTimeoutSeconds 120 `
        -RuntimeEngineReadyPollSeconds 3 `
        -RuntimeSnapshotPath $runtimeSnapshotPath
      $compareExit = $LASTEXITCODE
      if ($compareExit -notin @(0, 1)) {
        throw ("NI image flag scenario '{0}' compare failed (exit={1})." -f $activeScenarioName, $compareExit)
      }
    } finally {
      Pop-Location | Out-Null
    }

    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
      throw ("NI image flag scenario '{0}' capture missing: {1}" -f $activeScenarioName, $capturePath)
    }
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 20
    $gateOutcome = if ($capture.PSObject.Properties['gateOutcome']) { [string]$capture.gateOutcome } else { '' }
    $resultClass = if ($capture.PSObject.Properties['resultClass']) { [string]$capture.resultClass } else { '' }
    $imageUsed = if ($capture.PSObject.Properties['image']) { [string]$capture.image } else { '' }
    $commandText = if ($capture.PSObject.Properties['command']) { [string]$capture.command } else { '' }
    $flagsUsed = @()
    if ($capture.PSObject.Properties['flags'] -and $capture.flags) {
      $flagsUsed = @($capture.flags | ForEach-Object { [string]$_ })
    }

    if (-not [string]::Equals($imageUsed, $expectedImage, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw ("NI image flag scenario '{0}' used unexpected image: {1}" -f $activeScenarioName, $imageUsed)
    }
    if (-not [string]::Equals($gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw ("NI image flag scenario '{0}' did not pass (resultClass={1}, gateOutcome={2})." -f $activeScenarioName, $resultClass, $gateOutcome)
    }
    if ([string]::IsNullOrWhiteSpace($commandText) -or $commandText -notmatch '(?i)docker run') {
      throw ("NI image flag scenario '{0}' did not emit a docker run command in capture evidence." -f $activeScenarioName)
    }
    foreach ($flag in $activeScenarioFlags) {
      if ($flagsUsed -notcontains $flag) {
        throw ("NI image flag scenario '{0}' missing expected flag in capture: {1}" -f $activeScenarioName, $flag)
      }
    }
    if ($flagsUsed -notcontains '-Headless') {
      throw ("NI image flag scenario '{0}' missing enforced -Headless flag in capture." -f $activeScenarioName)
    }

    $scenarioResults.Add([pscustomobject]@{
      name = $activeScenarioName
      requestedFlags = @($activeScenarioFlags)
      flags = @($flagsUsed)
      resultClass = $resultClass
      gateOutcome = $gateOutcome
      capturePath = $capturePath
      reportPath = $reportPath
    }) | Out-Null
  }

  $activeScenarioName = 'single-container-matrix'
  $activeScenarioFlags = @()
  $scenarioDir = Join-Path $scenarioRoot $activeScenarioName
  $singleContainerResultsDir = Join-Path $scenarioDir 'matrix-results'
  New-Item -ItemType Directory -Path $singleContainerResultsDir -Force | Out-Null
  $reportPath = Join-Path $scenarioDir 'compare-report.html'
  $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
  $capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'
  $singleContainerContractPath = Join-Path $scenarioDir 'runtime-bootstrap.json'
  $singleContainerLedgerPath = Join-Path $singleContainerResultsDir 'flag-matrix-ledger.tsv'
  $singleContainerMarkerPath = Join-Path $singleContainerResultsDir 'flag-matrix-ran.txt'
  $singleContainerContract = [ordered]@{
    schema = 'ni-linux-runtime-bootstrap/v1'
    mode = 'flag-matrix-single-container'
    scriptPath = $singleContainerBootstrapScript
    env = @(
      [ordered]@{
        name = 'COMPAREVI_FLAG_MATRIX_RESULTS_DIR'
        value = '/opt/comparevi/flag-matrix'
      }
    )
    mounts = @(
      [ordered]@{
        hostPath = $singleContainerResultsDir
        containerPath = '/opt/comparevi/flag-matrix'
      }
    )
  }
  $singleContainerContract | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $singleContainerContractPath -Encoding utf8

  Write-Host '[pre-push] Running NI image flag scenario group single-container-matrix requestedFlags=all combinations' -ForegroundColor Cyan
  Push-Location $root
  try {
    & $niCompareScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -Image $expectedImage `
      -ReportPath $reportPath `
      -LabVIEWPath $containerLabVIEWPath `
      -ContainerNameLabel $activeScenarioName `
      -TimeoutSeconds 240 `
      -HeartbeatSeconds 15 `
      -AutoRepairRuntime:$true `
      -RuntimeEngineReadyTimeoutSeconds 120 `
      -RuntimeEngineReadyPollSeconds 3 `
      -RuntimeSnapshotPath $runtimeSnapshotPath `
      -RuntimeBootstrapContractPath $singleContainerContractPath
    $compareExit = $LASTEXITCODE
    if ($compareExit -notin @(0, 1)) {
      throw ("NI image flag scenario '{0}' compare failed (exit={1})." -f $activeScenarioName, $compareExit)
    }
  } finally {
    Pop-Location | Out-Null
  }

  if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' capture missing: {1}" -f $activeScenarioName, $capturePath)
  }
  $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 20
  $gateOutcome = if ($capture.PSObject.Properties['gateOutcome']) { [string]$capture.gateOutcome } else { '' }
  $resultClass = if ($capture.PSObject.Properties['resultClass']) { [string]$capture.resultClass } else { '' }
  $imageUsed = if ($capture.PSObject.Properties['image']) { [string]$capture.image } else { '' }
  $commandText = if ($capture.PSObject.Properties['command']) { [string]$capture.command } else { '' }
  $flagsUsed = @()
  if ($capture.PSObject.Properties['flags'] -and $capture.flags) {
    $flagsUsed = @($capture.flags | ForEach-Object { [string]$_ })
  }

  if (-not [string]::Equals($imageUsed, $expectedImage, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("NI image flag scenario '{0}' used unexpected image: {1}" -f $activeScenarioName, $imageUsed)
  }
  if (-not [string]::Equals($gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("NI image flag scenario '{0}' did not pass (resultClass={1}, gateOutcome={2})." -f $activeScenarioName, $resultClass, $gateOutcome)
  }
  if ([string]::IsNullOrWhiteSpace($commandText) -or $commandText -notmatch '(?i)docker run') {
    throw ("NI image flag scenario '{0}' did not emit a docker run command in capture evidence." -f $activeScenarioName)
  }
  if ($flagsUsed -notcontains '-Headless') {
    throw ("NI image flag scenario '{0}' missing enforced -Headless flag in capture." -f $activeScenarioName)
  }
  if (-not (Test-Path -LiteralPath $singleContainerLedgerPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing single-container ledger: {1}" -f $activeScenarioName, $singleContainerLedgerPath)
  }
  if (-not (Test-Path -LiteralPath $singleContainerMarkerPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing single-container marker: {1}" -f $activeScenarioName, $singleContainerMarkerPath)
  }

  $ledgerRows = @(Get-Content -LiteralPath $singleContainerLedgerPath | Where-Object { $_ -and $_.Trim() })
  if ($ledgerRows.Count -ne $knownFlagScenarios.Count) {
    throw ("NI image flag scenario '{0}' ledger count mismatch ({1} != {2})." -f $activeScenarioName, $ledgerRows.Count, $knownFlagScenarios.Count)
  }
  $ledgerEntries = @(
    $ledgerRows | ForEach-Object {
      $parts = [string]$_ -split "`t"
      [pscustomobject]@{
        index = if ($parts.Count -gt 0) { [int]$parts[0] } else { 0 }
        name = if ($parts.Count -gt 1) { [string]$parts[1] } else { '' }
        requestedFlags = if ($parts.Count -gt 2) { [string]$parts[2] } else { '' }
        exitCode = if ($parts.Count -gt 3) { [int]$parts[3] } else { 0 }
        status = if ($parts.Count -gt 4) { [string]$parts[4] } else { '' }
        diff = if ($parts.Count -gt 5) { [string]$parts[5] } else { '' }
        reportPath = if ($parts.Count -gt 6) { [string]$parts[6] } else { '' }
        logPath = if ($parts.Count -gt 7) { [string]$parts[7] } else { '' }
      }
    }
  )
  $expectedScenarioNames = @($knownFlagScenarios | ForEach-Object { [string]$_.name })
  $actualScenarioNames = @($ledgerEntries | ForEach-Object { [string]$_.name })
  $scenarioNameDifferences = @(Compare-Object -ReferenceObject $expectedScenarioNames -DifferenceObject $actualScenarioNames)
  if ($scenarioNameDifferences.Count -gt 0) {
    throw ("NI image flag scenario '{0}' ledger names did not match the expected combination set." -f $activeScenarioName)
  }
  $failureMarkers = @(
    'Report path already exists:'
    'Use -o to overwrite existing report.'
    'CreateComparisonReport operation failed.'
  )
  foreach ($entry in $ledgerEntries) {
    $resolvedEntryLogPath = Resolve-ContainerMountedHostPath -Path $entry.logPath -Mounts @($capture.runtimeInjection.mounts)
    if ([string]::IsNullOrWhiteSpace($resolvedEntryLogPath) -or -not (Test-Path -LiteralPath $resolvedEntryLogPath -PathType Leaf)) {
      throw ("NI image flag scenario '{0}' missing single-container CLI log for {1}: {2} (resolved: {3})" -f $activeScenarioName, $entry.name, $entry.logPath, $resolvedEntryLogPath)
    }
    if (-not [string]::Equals($entry.status, 'completed', [System.StringComparison]::OrdinalIgnoreCase)) {
      $entryLogTail = Get-LogTailText -Path $resolvedEntryLogPath
      throw ("NI image flag scenario '{0}' recorded non-completed ledger status for {1}: {2}`nlog={3}`n{4}" -f $activeScenarioName, $entry.name, $entry.status, $resolvedEntryLogPath, $entryLogTail)
    }
    $hasFailureText = Select-String -Path $resolvedEntryLogPath -SimpleMatch -Quiet -Pattern $failureMarkers -ErrorAction SilentlyContinue
    if ($hasFailureText) {
      $entryLogTail = Get-LogTailText -Path $resolvedEntryLogPath
      throw ("NI image flag scenario '{0}' detected wrapper/tool failure text for {1}`nlog={2}`n{3}" -f $activeScenarioName, $entry.name, $resolvedEntryLogPath, $entryLogTail)
    }
    $resolvedEntryReportPath = Resolve-ContainerMountedHostPath -Path $entry.reportPath -Mounts @($capture.runtimeInjection.mounts)
    if (-not (Test-Path -LiteralPath $resolvedEntryReportPath -PathType Leaf)) {
      throw ("NI image flag scenario '{0}' missing single-container report for {1}: {2} (resolved: {3})" -f $activeScenarioName, $entry.name, $entry.reportPath, $resolvedEntryReportPath)
    }
  }

  $scenarioResults.Add([pscustomobject]@{
    name = $activeScenarioName
    requestedFlags = @('all combinations')
    flags = @($flagsUsed)
    resultClass = $resultClass
    gateOutcome = $gateOutcome
    capturePath = $capturePath
    reportPath = $reportPath
  }) | Out-Null

  $activeScenarioName = 'vi-history-report'
  $activeScenarioFlags = @('vi-history-suite')
  $scenarioDir = Join-Path $scenarioRoot $activeScenarioName
  $viHistoryResultsDir = Join-Path $scenarioDir 'results'
  New-Item -ItemType Directory -Path $viHistoryResultsDir -Force | Out-Null
  $reportPath = Join-Path $viHistoryResultsDir 'linux-compare-report.html'
  $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
  $capturePath = Join-Path $viHistoryResultsDir 'ni-linux-container-capture.json'
  $viHistoryContractPath = Join-Path $scenarioDir 'runtime-bootstrap.json'
  $viHistoryManifestPath = Join-Path $viHistoryResultsDir 'suite-manifest.json'
  $viHistoryContextPath = Join-Path $viHistoryResultsDir 'history-context.json'
  $viHistoryReceiptPath = Join-Path $viHistoryResultsDir 'vi-history-bootstrap-receipt.json'
  $viHistoryMarkdownPath = Join-Path $viHistoryResultsDir 'history-report.md'
  $viHistoryHtmlPath = Join-Path $viHistoryResultsDir 'history-report.html'
  $viHistorySummaryJsonPath = Join-Path $viHistoryResultsDir 'history-summary.json'
  $viHistoryInspectionJsonPath = Join-Path $viHistoryResultsDir 'history-suite-inspection.json'
  $viHistoryInspectionHtmlPath = Join-Path $viHistoryResultsDir 'history-suite-inspection.html'
  $viHistoryContract = [ordered]@{
    schema = 'ni-linux-runtime-bootstrap/v1'
    mode = 'vi-history-suite-smoke'
    branchRef = 'develop'
    maxCommitCount = 64
    scriptPath = $viHistoryBootstrapScript
    viHistory = [ordered]@{
      repoPath = $root
      targetPath = 'fixtures/vi-attr/Head.vi'
      resultsPath = $viHistoryResultsDir
      baselineRef = 'develop'
      maxPairs = 2
    }
  }
  $viHistoryContract | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $viHistoryContractPath -Encoding utf8

  Write-Host '[pre-push] Running NI image flag scenario group vi-history-report requestedFlags=vi-history-suite' -ForegroundColor Cyan
  Push-Location $root
  try {
    & $niCompareScript `
      -Image $expectedImage `
      -ReportPath $reportPath `
      -LabVIEWPath $containerLabVIEWPath `
      -ContainerNameLabel $activeScenarioName `
      -TimeoutSeconds 240 `
      -HeartbeatSeconds 15 `
      -AutoRepairRuntime:$true `
      -RuntimeEngineReadyTimeoutSeconds 120 `
      -RuntimeEngineReadyPollSeconds 3 `
      -RuntimeSnapshotPath $runtimeSnapshotPath `
      -RuntimeBootstrapContractPath $viHistoryContractPath
    $compareExit = $LASTEXITCODE
    if ($compareExit -notin @(0, 1)) {
      throw ("NI image flag scenario '{0}' compare failed (exit={1})." -f $activeScenarioName, $compareExit)
    }
  } finally {
    Pop-Location | Out-Null
  }

  if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' capture missing: {1}" -f $activeScenarioName, $capturePath)
  }
  $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 20
  $gateOutcome = if ($capture.PSObject.Properties['gateOutcome']) { [string]$capture.gateOutcome } else { '' }
  $resultClass = if ($capture.PSObject.Properties['resultClass']) { [string]$capture.resultClass } else { '' }
  $imageUsed = if ($capture.PSObject.Properties['image']) { [string]$capture.image } else { '' }
  $commandText = if ($capture.PSObject.Properties['command']) { [string]$capture.command } else { '' }

  if (-not [string]::Equals($imageUsed, $expectedImage, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("NI image flag scenario '{0}' used unexpected image: {1}" -f $activeScenarioName, $imageUsed)
  }
  if (-not [string]::Equals($gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("NI image flag scenario '{0}' did not pass (resultClass={1}, gateOutcome={2})." -f $activeScenarioName, $resultClass, $gateOutcome)
  }
  if ([string]::IsNullOrWhiteSpace($commandText) -or $commandText -notmatch '(?i)docker run') {
    throw ("NI image flag scenario '{0}' did not emit a docker run command in capture evidence." -f $activeScenarioName)
  }
  if (-not (Test-Path -LiteralPath $viHistoryManifestPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing VI history manifest: {1}" -f $activeScenarioName, $viHistoryManifestPath)
  }
  if (-not (Test-Path -LiteralPath $viHistoryContextPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing VI history context: {1}" -f $activeScenarioName, $viHistoryContextPath)
  }
  if (-not (Test-Path -LiteralPath $viHistoryReceiptPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing VI history bootstrap receipt: {1}" -f $activeScenarioName, $viHistoryReceiptPath)
  }
  $viHistoryManifest = Get-Content -LiteralPath $viHistoryManifestPath -Raw | ConvertFrom-Json -Depth 20
  if (-not $viHistoryManifest.stats -or [int]$viHistoryManifest.stats.processed -lt 1) {
    throw ("NI image flag scenario '{0}' generated an empty VI history suite manifest." -f $activeScenarioName)
  }
  foreach ($artifactPath in @($viHistoryMarkdownPath, $viHistoryHtmlPath, $viHistorySummaryJsonPath)) {
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      throw ("NI image flag scenario '{0}' missing in-container VI history artifact: {1}" -f $activeScenarioName, $artifactPath)
    }
  }
  $viHistoryReceipt = Get-Content -LiteralPath $viHistoryReceiptPath -Raw | ConvertFrom-Json -Depth 20
  foreach ($receiptProperty in @('historyReportMarkdownPath', 'historyReportHtmlPath', 'historySummaryPath')) {
    if (-not $viHistoryReceipt.PSObject.Properties[$receiptProperty]) {
      throw ("NI image flag scenario '{0}' missing receipt property: {1}" -f $activeScenarioName, $receiptProperty)
    }
  }
  if ([string]$viHistoryReceipt.historyReportMarkdownPath -notmatch 'history-report\.md$') {
    throw ("NI image flag scenario '{0}' receipt markdown path is not normalized: {1}" -f $activeScenarioName, $viHistoryReceipt.historyReportMarkdownPath)
  }
  if ([string]$viHistoryReceipt.historyReportHtmlPath -notmatch 'history-report\.html$') {
    throw ("NI image flag scenario '{0}' receipt html path is not normalized: {1}" -f $activeScenarioName, $viHistoryReceipt.historyReportHtmlPath)
  }
  if ([string]$viHistoryReceipt.historySummaryPath -notmatch 'history-summary\.json$') {
    throw ("NI image flag scenario '{0}' receipt summary path is not normalized: {1}" -f $activeScenarioName, $viHistoryReceipt.historySummaryPath)
  }
  $viHistorySummary = Get-Content -LiteralPath $viHistorySummaryJsonPath -Raw | ConvertFrom-Json -Depth 20
  if (-not [string]::Equals([string]$viHistorySummary.schema, 'comparevi-tools/history-facade@v1', [System.StringComparison]::Ordinal)) {
    throw ("NI image flag scenario '{0}' emitted an unexpected VI history summary schema: {1}" -f $activeScenarioName, $viHistorySummary.schema)
  }
  if (-not $viHistorySummary.summary -or [int]$viHistorySummary.summary.comparisons -lt 1) {
    throw ("NI image flag scenario '{0}' emitted an empty VI history summary facade." -f $activeScenarioName)
  }
  if (-not $viHistorySummary.reports -or [string]::IsNullOrWhiteSpace([string]$viHistorySummary.reports.htmlPath)) {
    throw ("NI image flag scenario '{0}' missing HTML report path in VI history summary facade." -f $activeScenarioName)
  }
  & (Join-Path $root 'tools' 'Inspect-VIHistorySuiteArtifacts.ps1') `
    -ResultsDir $viHistoryResultsDir `
    -HistoryReportPath $viHistoryHtmlPath `
    -HistorySummaryPath $viHistorySummaryJsonPath `
    -OutputJsonPath $viHistoryInspectionJsonPath `
    -OutputHtmlPath $viHistoryInspectionHtmlPath `
    -GitHubOutputPath '' `
    -GitHubStepSummaryPath ''
  if (-not (Test-Path -LiteralPath $viHistoryInspectionJsonPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing VI history inspection JSON: {1}" -f $activeScenarioName, $viHistoryInspectionJsonPath)
  }
  if (-not (Test-Path -LiteralPath $viHistoryInspectionHtmlPath -PathType Leaf)) {
    throw ("NI image flag scenario '{0}' missing VI history inspection HTML: {1}" -f $activeScenarioName, $viHistoryInspectionHtmlPath)
  }

  $scenarioResults.Add([pscustomobject]@{
    name = $activeScenarioName
    requestedFlags = @('vi-history-suite')
    flags = @('suite-manifest', 'history-report', 'history-summary')
    resultClass = $resultClass
    gateOutcome = $gateOutcome
    capturePath = $capturePath
    reportPath = $viHistoryHtmlPath
  }) | Out-Null

  if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('### Pre-push NI Image Scenarios', '')
    foreach ($scenarioResult in $scenarioResults) {
      $requestedFlags = if (@($scenarioResult.requestedFlags).Count -eq 0) { '(none)' } else { [string]::Join(', ', @($scenarioResult.requestedFlags)) }
      $lines += ('- `{0}`: resultClass=`{1}` gateOutcome=`{2}` requestedFlags=`{3}` effectiveFlags=`{4}`' -f $scenarioResult.name, $scenarioResult.resultClass, $scenarioResult.gateOutcome, $requestedFlags, [string]::Join(', ', @($scenarioResult.flags)))
      $lines += ('  capture=`{0}` report=`{1}`' -f $scenarioResult.capturePath, $scenarioResult.reportPath)
    }
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }
  Write-Host '[pre-push] VI Comparison Report flag combination scenarios OK' -ForegroundColor Green
} catch {
  $failureMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { [string]$_ }
  $eventReportPath = Write-PrePushNIKnownFlagIncidentEvent `
    -repoRoot $root `
    -errorMessage $failureMessage `
    -scenarioName $activeScenarioName `
    -scenarioDir $scenarioDir `
    -capturePath $capturePath `
    -expectedImage $expectedImage `
    -containerLabVIEWPath $containerLabVIEWPath `
    -scenarioFlags $activeScenarioFlags `
    -reportPath $reportPath `
    -runtimeSnapshotPath $runtimeSnapshotPath
  if (-not [string]::IsNullOrWhiteSpace($eventReportPath)) {
    Write-Host ("[pre-push] NI known-flag incident event report: {0}" -f $eventReportPath) -ForegroundColor Yellow
  }
  throw
}
