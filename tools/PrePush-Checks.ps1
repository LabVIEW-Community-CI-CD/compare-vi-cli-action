#Requires -Version 7.0
<#
.SYNOPSIS
  Local pre-push checks: run actionlint against workflows.
.DESCRIPTION
  Ensures a valid actionlint binary is used per-OS and runs it against .github/workflows.
  On Windows, explicitly prefers bin/actionlint.exe to avoid invoking the non-Windows binary.
.PARAMETER ActionlintVersion
  Optional version to install if missing (default: 1.7.8). Only used when auto-installing.
.PARAMETER InstallIfMissing
  Attempt to install actionlint if not found (default: true).
#>
param(
  [string]$ActionlintVersion = '1.7.8',
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
    break
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
    throw 'PSScriptAnalyzer not installed; install the module or rerun with -SkipPSScriptAnalyzer.'
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
    [string]$scenarioId,
    [string]$scenarioName,
    [string]$scenarioDir,
    [string]$capturePath,
    [string]$expectedImage,
    [string]$containerLabVIEWPath,
    [string[]]$scenarioFlags,
    [string]$reportPath,
    [string]$runtimeSnapshotPath,
    [string]$incidentInputPath,
    [string]$incidentEventPath
  )

  $eventIngestScript = Join-Path $repoRoot 'tools' 'priority' 'event-ingest.mjs'
  if (-not (Test-Path -LiteralPath $eventIngestScript -PathType Leaf)) {
    Write-Warning ("[pre-push] event-ingest script missing; cannot emit NI known-flag incident event: {0}" -f $eventIngestScript)
    return $null
  }

  $canaryDir = Join-Path $repoRoot 'tests' 'results' '_agent' 'canary'
  if ([string]::IsNullOrWhiteSpace($incidentInputPath)) {
    $incidentInputPath = Join-Path $canaryDir 'pre-push-ni-known-flag-incident-input.json'
  }
  if ([string]::IsNullOrWhiteSpace($incidentEventPath)) {
    $incidentEventPath = Join-Path $canaryDir 'pre-push-ni-known-flag-incident-event.json'
  }
  $inputDir = Split-Path -Parent $incidentInputPath
  $eventDir = Split-Path -Parent $incidentEventPath
  if (-not [string]::IsNullOrWhiteSpace($inputDir)) {
    New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($eventDir)) {
    New-Item -ItemType Directory -Path $eventDir -Force | Out-Null
  }
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
      scenarioId = $scenarioId
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

  $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $incidentInputPath -Encoding utf8
  & node $eventIngestScript `
    --source-type incident-event `
    --input $incidentInputPath `
    --report $incidentEventPath
  if ($LASTEXITCODE -ne 0) {
    Write-Warning ("[pre-push] NI known-flag incident normalization failed (exit={0})." -f $LASTEXITCODE)
    return $null
  }

  return $incidentEventPath
}

function Resolve-PrePushKnownFlagScenarioPack {
  param([string]$repoRoot)

  $contractPath = Join-Path $repoRoot 'tools' 'policy' 'prepush-known-flag-scenarios.json'
  if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw ("Pre-push known-flag scenario-pack contract not found: {0}" -f $contractPath)
  }

  try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json -Depth 20
  } catch {
    throw ("Unable to parse pre-push known-flag scenario-pack contract: {0}" -f $contractPath)
  }

  if ([string]$contract.schema -ne 'prepush-known-flag-scenario-packs/v1') {
    throw ("Unexpected pre-push known-flag scenario-pack contract schema in {0}: {1}" -f $contractPath, $contract.schema)
  }
  $scenarioPacks = @($contract.scenarioPacks)
  if ($scenarioPacks.Count -lt 1) {
    throw ("Pre-push known-flag scenario-pack contract defines no scenario packs: {0}" -f $contractPath)
  }
  $activeScenarioPacks = @($scenarioPacks | Where-Object { $_.isActive -eq $true })
  if ($activeScenarioPacks.Count -ne 1) {
    throw ("Pre-push known-flag scenario-pack contract must define exactly one active scenario pack: {0}" -f $contractPath)
  }

  $activeScenarioPack = $activeScenarioPacks[0]
  if ([string]::IsNullOrWhiteSpace([string]$activeScenarioPack.id)) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing id: {0}" -f $contractPath)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$contract.activeScenarioPackId) -and
      -not [string]::Equals([string]$contract.activeScenarioPackId, [string]$activeScenarioPack.id, [System.StringComparison]::Ordinal)) {
    throw ("Pre-push known-flag scenario-pack contract activeScenarioPackId did not match the active scenario pack id in {0}" -f $contractPath)
  }
  if ([string]::IsNullOrWhiteSpace([string]$activeScenarioPack.image)) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing image: {0}" -f $contractPath)
  }
  if ([string]::IsNullOrWhiteSpace([string]$activeScenarioPack.expectedGateOutcome)) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing expectedGateOutcome: {0}" -f $contractPath)
  }
  $packPlaneApplicability = @($activeScenarioPack.planeApplicability | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($packPlaneApplicability.Count -lt 1) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing planeApplicability: {0}" -f $contractPath)
  }
  if ([string]::IsNullOrWhiteSpace([string]$activeScenarioPack.priorityClass)) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing priorityClass: {0}" -f $contractPath)
  }
  if (-not $activeScenarioPack.target) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing target: {0}" -f $contractPath)
  }
  if ([string]::IsNullOrWhiteSpace([string]$activeScenarioPack.target.baseVi) -or
      [string]::IsNullOrWhiteSpace([string]$activeScenarioPack.target.headVi)) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack target is missing baseVi/headVi: {0}" -f $contractPath)
  }
  if (-not $activeScenarioPack.evidence) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing evidence paths: {0}" -f $contractPath)
  }
  if ([string]::IsNullOrWhiteSpace([string]$activeScenarioPack.evidence.resultsRoot) -or
      [string]::IsNullOrWhiteSpace([string]$activeScenarioPack.evidence.reportPath) -or
      [string]::IsNullOrWhiteSpace([string]$activeScenarioPack.evidence.incidentInputPath) -or
      [string]::IsNullOrWhiteSpace([string]$activeScenarioPack.evidence.incidentEventPath)) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack is missing evidence paths: {0}" -f $contractPath)
  }

  $declaredScenarios = @($activeScenarioPack.scenarios)
  if ($declaredScenarios.Count -lt 1) {
    throw ("Pre-push known-flag scenario-pack contract active scenario pack defines no scenarios: {0}" -f $contractPath)
  }

  $resolvedScenarioList = New-Object System.Collections.Generic.List[object]
  $scenarioIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
  foreach ($declaredScenario in $declaredScenarios) {
    $scenarioId = [string]$declaredScenario.id
    if ([string]::IsNullOrWhiteSpace($scenarioId)) {
      throw ("Pre-push known-flag scenario-pack contract scenario is missing id: {0}" -f $contractPath)
    }
    if (-not $scenarioIds.Add($scenarioId)) {
      throw ("Pre-push known-flag scenario-pack contract scenario ids must be unique: {0}" -f $scenarioId)
    }
    if ([string]::IsNullOrWhiteSpace([string]$declaredScenario.description)) {
      throw ("Pre-push known-flag scenario-pack contract scenario '{0}' is missing description: {1}" -f $scenarioId, $contractPath)
    }

    $scenarioFlags = @($declaredScenario.requestedFlags | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($flag in $scenarioFlags) {
      if (-not $flag.StartsWith('-', [System.StringComparison]::Ordinal)) {
        throw ("Pre-push known-flag scenario-pack contract flag must start with '-': {0}" -f $flag)
      }
    }

    if (-not $declaredScenario.intendedSuppressionSemantics) {
      throw ("Pre-push known-flag scenario-pack contract scenario '{0}' is missing intendedSuppressionSemantics: {1}" -f $scenarioId, $contractPath)
    }
    if (-not $declaredScenario.expectedReviewerAssertions -or @($declaredScenario.expectedReviewerAssertions).Count -lt 1) {
      throw ("Pre-push known-flag scenario-pack contract scenario '{0}' is missing expectedReviewerAssertions: {1}" -f $scenarioId, $contractPath)
    }
    if (-not $declaredScenario.expectedRawModeEvidenceBoundaries -or @($declaredScenario.expectedRawModeEvidenceBoundaries).Count -lt 1) {
      throw ("Pre-push known-flag scenario-pack contract scenario '{0}' is missing expectedRawModeEvidenceBoundaries: {1}" -f $scenarioId, $contractPath)
    }

    $scenarioPlaneApplicability = @()
    if ($declaredScenario.PSObject.Properties['planeApplicability'] -and $declaredScenario.planeApplicability) {
      $scenarioPlaneApplicability = @($declaredScenario.planeApplicability | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($scenarioPlaneApplicability.Count -lt 1) {
      $scenarioPlaneApplicability = @($packPlaneApplicability)
    }
    $scenarioPriorityClass = if (-not $declaredScenario.PSObject.Properties['priorityClass'] -or [string]::IsNullOrWhiteSpace([string]$declaredScenario.priorityClass)) {
      [string]$activeScenarioPack.priorityClass
    } else {
      [string]$declaredScenario.priorityClass
    }

    $suppressedCategories = @()
    if ($declaredScenario.intendedSuppressionSemantics.PSObject.Properties['suppressedCategories'] -and
        $declaredScenario.intendedSuppressionSemantics.suppressedCategories) {
      $suppressedCategories = @($declaredScenario.intendedSuppressionSemantics.suppressedCategories | ForEach-Object { [string]$_ })
    }

    $expectedReviewerAssertions = New-Object System.Collections.Generic.List[object]
    foreach ($assertion in @($declaredScenario.expectedReviewerAssertions)) {
      $expectedReviewerAssertions.Add([pscustomobject]@{
        id = [string]$assertion.id
        surface = [string]$assertion.surface
        requirement = [string]$assertion.requirement
      }) | Out-Null
    }

    $expectedRawModeEvidenceBoundaries = New-Object System.Collections.Generic.List[object]
    foreach ($boundary in @($declaredScenario.expectedRawModeEvidenceBoundaries)) {
      $expectedRawModeEvidenceBoundaries.Add([pscustomobject]@{
        id = [string]$boundary.id
        mode = [string]$boundary.mode
        surfaceRole = [string]$boundary.surfaceRole
        expectation = [string]$boundary.expectation
      }) | Out-Null
    }

    $resolvedScenarioList.Add([pscustomobject]@{
      id = $scenarioId
      description = [string]$declaredScenario.description
      requestedFlags = @($scenarioFlags)
      requestedFlagsLabel = if ($scenarioFlags.Count -eq 0) { '(none)' } else { [string]::Join(', ', $scenarioFlags) }
      planeApplicability = @($scenarioPlaneApplicability)
      priorityClass = $scenarioPriorityClass
      intendedSuppressionSemantics = [pscustomobject]@{
        suppressedCategories = @($suppressedCategories)
        reviewerSurfaceIntent = [string]$declaredScenario.intendedSuppressionSemantics.reviewerSurfaceIntent
        rawModeBoundaryIntent = [string]$declaredScenario.intendedSuppressionSemantics.rawModeBoundaryIntent
      }
      expectedReviewerAssertions = @($expectedReviewerAssertions.ToArray())
      expectedRawModeEvidenceBoundaries = @($expectedRawModeEvidenceBoundaries.ToArray())
    }) | Out-Null
  }

  return [pscustomobject]@{
    path = $contractPath
    pack = $activeScenarioPack
    scenarios = @($resolvedScenarioList.ToArray())
    resultsRoot = Join-Path $repoRoot ([string]$activeScenarioPack.evidence.resultsRoot)
    reportPath = Join-Path $repoRoot ([string]$activeScenarioPack.evidence.reportPath)
    incidentInputPath = Join-Path $repoRoot ([string]$activeScenarioPack.evidence.incidentInputPath)
    incidentEventPath = Join-Path $repoRoot ([string]$activeScenarioPack.evidence.incidentEventPath)
    baseVi = Join-Path $repoRoot ([string]$activeScenarioPack.target.baseVi)
    headVi = Join-Path $repoRoot ([string]$activeScenarioPack.target.headVi)
  }
}

function Write-PrePushKnownFlagScenarioReport {
  param(
    [string]$repoRoot,
    [object]$contract,
    [ValidateSet('pass', 'fail')]
    [string]$observedOutcome,
    [object[]]$scenarioResults,
    [string]$failureMessage,
    [string]$activeScenarioName,
    [string]$activeCapturePath,
    [string]$activeReportPath
  )

  if ($null -eq $contract) {
    return $null
  }

  $reportPath = [string]$contract.reportPath
  $reportDir = Split-Path -Parent $reportPath
  if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
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

  $report = [ordered]@{
    schema = 'pre-push-known-flag-scenario-pack-report@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    contractPath = [string]$contract.path
    branch = $branchName
    headSha = $sha
    scenarioPack = [ordered]@{
      id = [string]$contract.pack.id
      description = [string]$contract.pack.description
      image = [string]$contract.pack.image
      labviewPathEnv = [string]$contract.pack.labviewPathEnv
      defaultLabviewPath = [string]$contract.pack.defaultLabviewPath
      planeApplicability = @($contract.pack.planeApplicability | ForEach-Object { [string]$_ })
      priorityClass = [string]$contract.pack.priorityClass
      expectedGateOutcome = [string]$contract.pack.expectedGateOutcome
      target = [ordered]@{
        kind = [string]$contract.pack.target.kind
        baseVi = [string]$contract.pack.target.baseVi
        headVi = [string]$contract.pack.target.headVi
      }
      scenarioIds = @($contract.scenarios | ForEach-Object { [string]$_.id })
    }
    observed = [ordered]@{
      outcome = $observedOutcome
      activeScenarioId = $activeScenarioName
      capturePath = $activeCapturePath
      reportPath = $activeReportPath
      failureMessage = $failureMessage
    }
    results = @($scenarioResults)
  }
  $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8
  return $reportPath
}

function Write-PrePushRenderingCertificationReport {
  param(
    [string]$repoRoot,
    [object]$contract,
    [ValidateSet('pass', 'fail')]
    [string]$observedOutcome,
    [object[]]$scenarioResults,
    [string]$failureMessage,
    [string]$activeScenarioName,
    [string]$activeCapturePath,
    [string]$activeReportPath
  )

  if ($null -eq $contract) {
    return $null
  }

  $reportPath = Join-Path ([string]$contract.resultsRoot) 'post-results-rendering-certification-report.json'
  $reportDir = Split-Path -Parent $reportPath
  if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
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

  $allScenarioResults = @($scenarioResults)
  $failingScenarioResults = @($allScenarioResults | Where-Object { -not [string]::Equals([string]$_.semanticGateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase) })

  $report = [ordered]@{
    schema = 'pre-push-post-results-rendering-certification-report@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    contractPath = [string]$contract.path
    branch = $branchName
    headSha = $sha
    certificationPolicy = [ordered]@{
      scope = 'pre-push'
      blocking = $true
      subject = 'post-results-rendering'
      supportLaneReports = @(
        'transport-smoke-report.json',
        'vi-history-smoke-report.json'
      )
    }
    scenarioPack = [ordered]@{
      id = [string]$contract.pack.id
      description = [string]$contract.pack.description
      image = [string]$contract.pack.image
      expectedGateOutcome = [string]$contract.pack.expectedGateOutcome
      target = [ordered]@{
        kind = [string]$contract.pack.target.kind
        baseVi = [string]$contract.pack.target.baseVi
        headVi = [string]$contract.pack.target.headVi
      }
    }
    summary = [ordered]@{
      totalScenarios = $allScenarioResults.Count
      passingScenarios = @($allScenarioResults | Where-Object { [string]::Equals([string]$_.semanticGateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase) }).Count
      failingScenarios = $failingScenarioResults.Count
    }
    observed = [ordered]@{
      outcome = $observedOutcome
      activeScenarioId = $activeScenarioName
      capturePath = $activeCapturePath
      reportPath = $activeReportPath
      failureMessage = $failureMessage
    }
    results = @($scenarioResults)
  }
  $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $reportPath -Encoding utf8
  return $reportPath
}

function Write-PrePushSupportLaneReport {
  param(
    [string]$repoRoot,
    [string]$reportPath,
    [string]$schema,
    [string]$laneName,
    [string]$description,
    [ValidateSet('pass', 'fail', 'not-run')]
    [string]$observedOutcome,
    [object[]]$scenarioResults,
    [string]$failureMessage,
    [string]$capturePath,
    [string]$reportArtifactPath
  )

  if ([string]::IsNullOrWhiteSpace($reportPath)) {
    return $null
  }

  $reportDir = Split-Path -Parent $reportPath
  if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
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

  $report = [ordered]@{
    schema = $schema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    branch = $branchName
    headSha = $sha
    lane = [ordered]@{
      name = $laneName
      description = $description
    }
    observed = [ordered]@{
      outcome = $observedOutcome
      capturePath = $capturePath
      reportPath = $reportArtifactPath
      failureMessage = $failureMessage
    }
    results = @($scenarioResults)
  }
  $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8
  return $reportPath
}

function Get-PrePushKnownFlagScenarioSemanticEvidence {
  param(
    [Parameter(Mandatory)]
    [string]$ReportPath
  )

  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw ("Pre-push semantic evidence report not found: {0}" -f $ReportPath)
  }

  $html = Get-Content -LiteralPath $ReportPath -Raw
  if ([string]::IsNullOrWhiteSpace($html)) {
    throw ("Pre-push semantic evidence report is empty: {0}" -f $ReportPath)
  }

  $inclusionStates = [ordered]@{}
  $inclusionPattern = '<li\s+class="(?<class>checked|unchecked)">(?<label>[^<]+)</li>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($html, $inclusionPattern, 'IgnoreCase')) {
    $label = [System.Net.WebUtility]::HtmlDecode($match.Groups['label'].Value.Trim())
    if ([string]::IsNullOrWhiteSpace($label)) {
      continue
    }
    $inclusionStates[$label] = ($match.Groups['class'].Value.Trim().ToLowerInvariant() -eq 'checked')
  }

  $headingTexts = New-Object System.Collections.Generic.List[string]
  $headingPattern = '<summary\s+class="(?<class>[^"]*difference(?:-cosmetic)?-heading[^"]*)">\s*(?<text>.*?)\s*</summary>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($html, $headingPattern, 'IgnoreCase')) {
    $rawHeading = $match.Groups['text'].Value
    if ([string]::IsNullOrWhiteSpace($rawHeading)) {
      continue
    }
    $decodedHeading = [System.Net.WebUtility]::HtmlDecode($rawHeading.Trim())
    $decodedHeading = ($decodedHeading -replace '^\s*\d+\.\s*', '')
    if ([string]::IsNullOrWhiteSpace($decodedHeading)) {
      continue
    }
    $headingTexts.Add($decodedHeading) | Out-Null
  }

  $trackedCategories = [ordered]@{
    'Front Panel' = $null
    'Front Panel Position/Size' = $null
    'Block Diagram Functional' = $null
    'Block Diagram Cosmetic' = $null
    'VI Attribute' = $null
  }
  foreach ($categoryName in @($trackedCategories.Keys)) {
    if ($inclusionStates.Contains($categoryName)) {
      $trackedCategories[$categoryName] = [bool]$inclusionStates[$categoryName]
    }
  }

  return [pscustomobject]@{
    reportPath = $ReportPath
    inclusionStates = [pscustomobject]$inclusionStates
    trackedCategories = [pscustomobject]$trackedCategories
    headingTexts = @($headingTexts.ToArray())
    inclusionCount = $inclusionStates.Count
    headingCount = $headingTexts.Count
  }
}

function Test-PrePushKnownFlagReviewerAssertion {
  param(
    [Parameter(Mandatory)]
    [object]$Assertion,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$RequestedFlags,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$ObservedFlags,

    [Parameter(Mandatory)]
    [object]$SemanticEvidence
  )

  $requirement = [string]$Assertion.requirement
  $surface = [string]$Assertion.surface
  $passed = $false
  $details = ''

  switch ($requirement) {
    'rendered' {
      $passed = ($SemanticEvidence.inclusionCount -gt 0 -and $SemanticEvidence.headingCount -gt 0)
      $details = ("inclusionCount={0}; headingCount={1}" -f $SemanticEvidence.inclusionCount, $SemanticEvidence.headingCount)
    }
    'requested-flags-observed' {
      $missingFlags = New-Object System.Collections.Generic.List[string]
      foreach ($requestedFlag in @($RequestedFlags)) {
        if ($ObservedFlags -notcontains $requestedFlag) {
          $missingFlags.Add([string]$requestedFlag) | Out-Null
        }
      }
      if ($ObservedFlags -notcontains '-Headless') {
        $missingFlags.Add('-Headless') | Out-Null
      }
      $passed = ($missingFlags.Count -eq 0)
      $details = if ($passed) {
        ("observedFlags={0}" -f ([string]::Join(', ', @($ObservedFlags))))
      } else {
        ("missingFlags={0}; observedFlags={1}" -f ([string]::Join(', ', @($missingFlags)), [string]::Join(', ', @($ObservedFlags))))
      }
    }
    'attribute-suppression-boundary-visible' {
      $state = $SemanticEvidence.trackedCategories.'VI Attribute'
      $passed = ($null -ne $state -and -not [bool]$state)
      $details = ("VI Attribute checked={0}" -f $state)
    }
    'front-panel-position-boundary-visible' {
      $state = $SemanticEvidence.trackedCategories.'Front Panel Position/Size'
      $passed = ($null -ne $state -and -not [bool]$state)
      $details = ("Front Panel Position/Size checked={0}" -f $state)
    }
    'block-diagram-cosmetic-boundary-visible' {
      $state = $SemanticEvidence.trackedCategories.'Block Diagram Cosmetic'
      $passed = ($null -ne $state -and -not [bool]$state)
      $details = ("Block Diagram Cosmetic checked={0}" -f $state)
    }
    default {
      throw ("Unsupported pre-push known-flag reviewer assertion requirement: {0}" -f $requirement)
    }
  }

  return [pscustomobject]@{
    id = [string]$Assertion.id
    surface = $surface
    requirement = $requirement
    passed = [bool]$passed
    details = $details
  }
}

function Test-PrePushKnownFlagRawModeBoundary {
  param(
    [Parameter(Mandatory)]
    [object]$Boundary,

    [Parameter(Mandatory)]
    [object]$SemanticEvidence
  )

  $expectation = [string]$Boundary.expectation
  $passed = $false
  $details = ''

  switch ($expectation) {
    'full-surface' {
      $trackedStates = $SemanticEvidence.trackedCategories.PSObject.Properties | ForEach-Object { $_.Value }
      $missingStates = @($trackedStates | Where-Object { $null -eq $_ })
      $uncheckedStates = @($trackedStates | Where-Object { $null -ne $_ -and -not [bool]$_ })
      $passed = ($missingStates.Count -eq 0 -and $uncheckedStates.Count -eq 0)
      $details = ("trackedCategories={0}" -f (($SemanticEvidence.trackedCategories | ConvertTo-Json -Compress)))
    }
    'vi-attributes-suppressed' {
      $state = $SemanticEvidence.trackedCategories.'VI Attribute'
      $passed = ($null -ne $state -and -not [bool]$state)
      $details = ("VI Attribute checked={0}" -f $state)
    }
    'front-panel-position-size-suppressed' {
      $state = $SemanticEvidence.trackedCategories.'Front Panel Position/Size'
      $passed = ($null -ne $state -and -not [bool]$state)
      $details = ("Front Panel Position/Size checked={0}" -f $state)
    }
    'block-diagram-cosmetic-suppressed' {
      $state = $SemanticEvidence.trackedCategories.'Block Diagram Cosmetic'
      $passed = ($null -ne $state -and -not [bool]$state)
      $details = ("Block Diagram Cosmetic checked={0}" -f $state)
    }
    default {
      throw ("Unsupported pre-push known-flag raw-mode expectation: {0}" -f $expectation)
    }
  }

  return [pscustomobject]@{
    id = [string]$Boundary.id
    mode = [string]$Boundary.mode
    surfaceRole = [string]$Boundary.surfaceRole
    expectation = $expectation
    passed = [bool]$passed
    details = $details
  }
}

function New-PrePushTransportMatrixScenarios {
  param(
    [AllowNull()]
    [object[]]$scenarioDefinitions
  )

  $baseFlagOptions = New-Object System.Collections.Generic.List[object]
  $seenFlags = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
  foreach ($scenarioDefinition in @($scenarioDefinitions)) {
    if ($null -eq $scenarioDefinition) {
      continue
    }
    $requestedFlags = @()
    if ($scenarioDefinition.PSObject.Properties['requestedFlags'] -and $scenarioDefinition.requestedFlags) {
      $requestedFlags = @($scenarioDefinition.requestedFlags | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    foreach ($requestedFlag in $requestedFlags) {
      if ($seenFlags.Add($requestedFlag)) {
        $baseFlagOptions.Add([pscustomobject]@{
          label = ([string]$requestedFlag).TrimStart('-')
          flag = [string]$requestedFlag
        }) | Out-Null
      }
    }
  }

  $transportMatrixScenarioBuffer = New-Object System.Collections.Generic.List[object]
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

    $transportMatrixScenarioBuffer.Add([pscustomobject]@{
      name = if ($scenarioLabels.Count -eq 0) { 'baseline' } else { [string]::Join('__', $scenarioLabels) }
      flags = @($scenarioFlags)
      requestedFlagsLabel = if ($scenarioFlags.Count -eq 0) { '(none)' } else { [string]::Join(', ', $scenarioFlags) }
      orderKey = if ($selectedIndices.Count -eq 0) { 'none' } else { [string]::Join('-', @($selectedIndices | ForEach-Object { '{0:d2}' -f $_ })) }
    }) | Out-Null
  }

  return @($transportMatrixScenarioBuffer | Sort-Object @{ Expression = { $_.flags.Count } }, @{ Expression = { $_.orderKey } })
}

function ConvertTo-PrePushKnownFlagScenarioResultArray {
  param(
    [AllowNull()]
    [object]$scenarioResults
  )

  $normalizedResults = New-Object System.Collections.Generic.List[object]
  foreach ($scenarioResult in $scenarioResults) {
    if ($null -eq $scenarioResult) {
      continue
    }

    $requestedFlags = @()
    if ($scenarioResult.PSObject.Properties['requestedFlags'] -and $scenarioResult.requestedFlags) {
      $requestedFlags = @($scenarioResult.requestedFlags | ForEach-Object { [string]$_ })
    }

    $flags = @()
    if ($scenarioResult.PSObject.Properties['flags'] -and $scenarioResult.flags) {
      $flags = @($scenarioResult.flags | ForEach-Object { [string]$_ })
    }

    $planeApplicability = @()
    if ($scenarioResult.PSObject.Properties['planeApplicability'] -and $scenarioResult.planeApplicability) {
      $planeApplicability = @($scenarioResult.planeApplicability | ForEach-Object { [string]$_ })
    }

    $suppressedCategories = @()
    $reviewerSurfaceIntent = ''
    $rawModeBoundaryIntent = ''
    if ($scenarioResult.PSObject.Properties['intendedSuppressionSemantics'] -and $scenarioResult.intendedSuppressionSemantics) {
      if ($scenarioResult.intendedSuppressionSemantics.PSObject.Properties['suppressedCategories'] -and
          $scenarioResult.intendedSuppressionSemantics.suppressedCategories) {
        $suppressedCategories = @($scenarioResult.intendedSuppressionSemantics.suppressedCategories | ForEach-Object { [string]$_ })
      }
      if ($scenarioResult.intendedSuppressionSemantics.PSObject.Properties['reviewerSurfaceIntent']) {
        $reviewerSurfaceIntent = [string]$scenarioResult.intendedSuppressionSemantics.reviewerSurfaceIntent
      }
      if ($scenarioResult.intendedSuppressionSemantics.PSObject.Properties['rawModeBoundaryIntent']) {
        $rawModeBoundaryIntent = [string]$scenarioResult.intendedSuppressionSemantics.rawModeBoundaryIntent
      }
    }

    $expectedReviewerAssertions = New-Object System.Collections.Generic.List[object]
    if ($scenarioResult.PSObject.Properties['expectedReviewerAssertions'] -and $scenarioResult.expectedReviewerAssertions) {
      foreach ($assertion in @($scenarioResult.expectedReviewerAssertions)) {
        if ($null -eq $assertion) {
          continue
        }
        $expectedReviewerAssertions.Add([pscustomobject]@{
          id = [string]$assertion.id
          surface = [string]$assertion.surface
          requirement = [string]$assertion.requirement
        }) | Out-Null
      }
    }

    $expectedRawModeEvidenceBoundaries = New-Object System.Collections.Generic.List[object]
    if ($scenarioResult.PSObject.Properties['expectedRawModeEvidenceBoundaries'] -and $scenarioResult.expectedRawModeEvidenceBoundaries) {
      foreach ($boundary in @($scenarioResult.expectedRawModeEvidenceBoundaries)) {
        if ($null -eq $boundary) {
          continue
        }
        $expectedRawModeEvidenceBoundaries.Add([pscustomobject]@{
          id = [string]$boundary.id
          mode = [string]$boundary.mode
          surfaceRole = [string]$boundary.surfaceRole
          expectation = [string]$boundary.expectation
        }) | Out-Null
      }
    }

    $reviewerAssertionResults = New-Object System.Collections.Generic.List[object]
    if ($scenarioResult.PSObject.Properties['reviewerAssertionResults'] -and $scenarioResult.reviewerAssertionResults) {
      foreach ($assertionResult in @($scenarioResult.reviewerAssertionResults)) {
        if ($null -eq $assertionResult) {
          continue
        }
        $reviewerAssertionResults.Add([pscustomobject]@{
          id = [string]$assertionResult.id
          surface = [string]$assertionResult.surface
          requirement = [string]$assertionResult.requirement
          passed = [bool]$assertionResult.passed
          details = [string]$assertionResult.details
        }) | Out-Null
      }
    }

    $rawModeBoundaryResults = New-Object System.Collections.Generic.List[object]
    if ($scenarioResult.PSObject.Properties['rawModeBoundaryResults'] -and $scenarioResult.rawModeBoundaryResults) {
      foreach ($boundaryResult in @($scenarioResult.rawModeBoundaryResults)) {
        if ($null -eq $boundaryResult) {
          continue
        }
        $rawModeBoundaryResults.Add([pscustomobject]@{
          id = [string]$boundaryResult.id
          mode = [string]$boundaryResult.mode
          surfaceRole = [string]$boundaryResult.surfaceRole
          expectation = [string]$boundaryResult.expectation
          passed = [bool]$boundaryResult.passed
          details = [string]$boundaryResult.details
        }) | Out-Null
      }
    }

    $semanticEvidence = $null
    if ($scenarioResult.PSObject.Properties['semanticEvidence'] -and $scenarioResult.semanticEvidence) {
      $trackedCategories = [ordered]@{}
      if ($scenarioResult.semanticEvidence.PSObject.Properties['trackedCategories'] -and $scenarioResult.semanticEvidence.trackedCategories) {
        foreach ($property in $scenarioResult.semanticEvidence.trackedCategories.PSObject.Properties) {
          $trackedCategories[$property.Name] = $property.Value
        }
      }

      $inclusionStates = [ordered]@{}
      if ($scenarioResult.semanticEvidence.PSObject.Properties['inclusionStates'] -and $scenarioResult.semanticEvidence.inclusionStates) {
        foreach ($property in $scenarioResult.semanticEvidence.inclusionStates.PSObject.Properties) {
          $inclusionStates[$property.Name] = $property.Value
        }
      }

      $semanticEvidence = [pscustomobject]@{
        reportPath = if ($scenarioResult.semanticEvidence.PSObject.Properties['reportPath']) { [string]$scenarioResult.semanticEvidence.reportPath } else { '' }
        inclusionStates = [pscustomobject]$inclusionStates
        trackedCategories = [pscustomobject]$trackedCategories
        headingTexts = if ($scenarioResult.semanticEvidence.PSObject.Properties['headingTexts'] -and $scenarioResult.semanticEvidence.headingTexts) {
          @($scenarioResult.semanticEvidence.headingTexts | ForEach-Object { [string]$_ })
        } else {
          @()
        }
        inclusionCount = if ($scenarioResult.semanticEvidence.PSObject.Properties['inclusionCount']) { [int]$scenarioResult.semanticEvidence.inclusionCount } else { 0 }
        headingCount = if ($scenarioResult.semanticEvidence.PSObject.Properties['headingCount']) { [int]$scenarioResult.semanticEvidence.headingCount } else { 0 }
      }
    }

    $normalizedResults.Add([pscustomobject]@{
      name = [string]$scenarioResult.name
      description = if ($scenarioResult.PSObject.Properties['description']) { [string]$scenarioResult.description } else { '' }
      requestedFlags = $requestedFlags
      flags = $flags
      planeApplicability = $planeApplicability
      priorityClass = if ($scenarioResult.PSObject.Properties['priorityClass']) { [string]$scenarioResult.priorityClass } else { '' }
      intendedSuppressionSemantics = [pscustomobject]@{
        suppressedCategories = @($suppressedCategories)
        reviewerSurfaceIntent = $reviewerSurfaceIntent
        rawModeBoundaryIntent = $rawModeBoundaryIntent
      }
      expectedReviewerAssertions = @($expectedReviewerAssertions.ToArray())
      expectedRawModeEvidenceBoundaries = @($expectedRawModeEvidenceBoundaries.ToArray())
      reviewerAssertionResults = @($reviewerAssertionResults.ToArray())
      rawModeBoundaryResults = @($rawModeBoundaryResults.ToArray())
      semanticEvidence = $semanticEvidence
      semanticGateOutcome = if ($scenarioResult.PSObject.Properties['semanticGateOutcome']) { [string]$scenarioResult.semanticGateOutcome } else { '' }
      resultClass = [string]$scenarioResult.resultClass
      gateOutcome = [string]$scenarioResult.gateOutcome
      capturePath = [string]$scenarioResult.capturePath
      reportPath = [string]$scenarioResult.reportPath
    }) | Out-Null
  }

  return @($normalizedResults.ToArray())
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
  Write-Host '[pre-push] Skipping VI Comparison Report scenario-pack and support lanes by request' -ForegroundColor Yellow
  return
}

$niCompareScript = Join-Path $root 'tools' 'Run-NILinuxContainerCompare.ps1'
if (-not (Test-Path -LiteralPath $niCompareScript -PathType Leaf)) {
  throw ("NI image compare script not found: {0}" -f $niCompareScript)
}
$knownFlagScenarioContract = Resolve-PrePushKnownFlagScenarioPack -repoRoot $root
$knownFlagScenarioPackId = [string]$knownFlagScenarioContract.pack.id
$baseVi = [string]$knownFlagScenarioContract.baseVi
$headVi = [string]$knownFlagScenarioContract.headVi
if (-not (Test-Path -LiteralPath $baseVi -PathType Leaf)) {
  throw ("Base VI not found for NI image known-flag scenario pack '{0}': {1}" -f $knownFlagScenarioPackId, $baseVi)
}
if (-not (Test-Path -LiteralPath $headVi -PathType Leaf)) {
  throw ("Head VI not found for NI image known-flag scenario pack '{0}': {1}" -f $knownFlagScenarioPackId, $headVi)
}

$expectedImage = [string]$knownFlagScenarioContract.pack.image
$labviewPathEnvName = [string]$knownFlagScenarioContract.pack.labviewPathEnv
$labviewPathFromEnv = if (-not [string]::IsNullOrWhiteSpace($labviewPathEnvName)) {
  [Environment]::GetEnvironmentVariable($labviewPathEnvName, 'Process')
} else {
  $null
}
$containerLabVIEWPath = if ([string]::IsNullOrWhiteSpace($labviewPathFromEnv)) {
  ([string]$knownFlagScenarioContract.pack.defaultLabviewPath).Trim()
} else {
  ([string]$labviewPathFromEnv).Trim()
}
if ([string]::IsNullOrWhiteSpace($containerLabVIEWPath)) {
  throw ("Pre-push known-flag scenario pack '{0}' resolved an empty LabVIEW path." -f $knownFlagScenarioPackId)
}
Write-Host ("[pre-push] Active known-flag scenario pack '{0}' image={1} scenarios={2}" -f $knownFlagScenarioPackId, $expectedImage, @($knownFlagScenarioContract.scenarios).Count) -ForegroundColor Cyan
$singleContainerBootstrapScript = Join-Path $root 'tools' 'NILinux-FlagMatrixBootstrap.sh'
if (-not (Test-Path -LiteralPath $singleContainerBootstrapScript -PathType Leaf)) {
  throw ("Single-container flag matrix bootstrap script not found: {0}" -f $singleContainerBootstrapScript)
}
$viHistoryBootstrapScript = Join-Path $root 'tools' 'NILinux-VIHistorySuiteBootstrap.sh'
if (-not (Test-Path -LiteralPath $viHistoryBootstrapScript -PathType Leaf)) {
  throw ("VI history bootstrap script not found: {0}" -f $viHistoryBootstrapScript)
}
$knownFlagScenarios = @($knownFlagScenarioContract.scenarios)
$transportMatrixScenarios = @(New-PrePushTransportMatrixScenarios -scenarioDefinitions $knownFlagScenarios)
$scenarioRoot = [string]$knownFlagScenarioContract.resultsRoot
New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
$scenarioContractReportPath = [string]$knownFlagScenarioContract.reportPath
$transportSmokeReportPath = Join-Path $scenarioRoot 'transport-smoke-report.json'
$viHistorySmokeReportPath = Join-Path $scenarioRoot 'vi-history-smoke-report.json'
$activeScenarioName = ''
$activeScenarioFlags = @()
$scenarioDir = $scenarioRoot
$reportPath = Join-Path $scenarioDir 'compare-report.html'
$runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
$capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'
$currentLane = 'known-flag'
$knownFlagScenarioResults = New-Object System.Collections.Generic.List[object]
$transportSmokeResults = New-Object System.Collections.Generic.List[object]
$viHistorySmokeResults = New-Object System.Collections.Generic.List[object]
$scenarioReportPath = $null
$renderingCertificationReportPath = $null
$transportLaneReportPath = $null
$viHistoryLaneReportPath = $null
$knownFlagObservedScenarioName = ''
$knownFlagObservedCapturePath = [string]$capturePath
$knownFlagObservedReportPath = [string]$reportPath
$transportObservedCapturePath = ''
$transportObservedReportPath = ''
$viHistoryObservedCapturePath = ''
$viHistoryObservedReportPath = ''
$observedCapturePath = [string]$capturePath
$observedReportPath = [string]$reportPath

try {
  Write-Host ("[pre-push] Running active known-flag scenario pack '{0}' (real container compare)" -f $knownFlagScenarioPackId) -ForegroundColor Cyan
  $currentLane = 'known-flag'
  foreach ($scenario in $knownFlagScenarios) {
    $activeScenarioName = [string]$scenario.id
    $activeScenarioFlags = @($scenario.requestedFlags | ForEach-Object { [string]$_ })
    $scenarioDir = Join-Path $scenarioRoot $activeScenarioName
    New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
    $reportPath = Join-Path $scenarioDir 'compare-report.html'
    $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
    $capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'
    $observedCapturePath = [string]$capturePath
    $observedReportPath = [string]$reportPath

    Write-Host ("[pre-push] Running NI image scenario-pack member '{0}' requestedFlags={1}" -f $activeScenarioName, [string]$scenario.requestedFlagsLabel) -ForegroundColor Cyan
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

    $semanticEvidence = Get-PrePushKnownFlagScenarioSemanticEvidence -ReportPath $reportPath
    $reviewerAssertionResults = New-Object System.Collections.Generic.List[object]
    foreach ($assertion in @($scenario.expectedReviewerAssertions)) {
      $assertionResult = Test-PrePushKnownFlagReviewerAssertion `
        -Assertion $assertion `
        -RequestedFlags $activeScenarioFlags `
        -ObservedFlags $flagsUsed `
        -SemanticEvidence $semanticEvidence
      $reviewerAssertionResults.Add($assertionResult) | Out-Null
    }

    $rawModeBoundaryResults = New-Object System.Collections.Generic.List[object]
    foreach ($boundary in @($scenario.expectedRawModeEvidenceBoundaries)) {
      $boundaryResult = Test-PrePushKnownFlagRawModeBoundary `
        -Boundary $boundary `
        -SemanticEvidence $semanticEvidence
      $rawModeBoundaryResults.Add($boundaryResult) | Out-Null
    }

    $semanticFailures = @(
      @($reviewerAssertionResults.ToArray() | Where-Object { -not $_.passed }) +
      @($rawModeBoundaryResults.ToArray() | Where-Object { -not $_.passed })
    )
    $semanticGateOutcome = if ($semanticFailures.Count -eq 0) { 'pass' } else { 'fail' }

    $knownFlagScenarioResults.Add([pscustomobject]@{
      name = $activeScenarioName
      description = [string]$scenario.description
      requestedFlags = @($activeScenarioFlags)
      flags = @($flagsUsed)
      planeApplicability = @($scenario.planeApplicability)
      priorityClass = [string]$scenario.priorityClass
      intendedSuppressionSemantics = $scenario.intendedSuppressionSemantics
      expectedReviewerAssertions = @($scenario.expectedReviewerAssertions)
      expectedRawModeEvidenceBoundaries = @($scenario.expectedRawModeEvidenceBoundaries)
      reviewerAssertionResults = @($reviewerAssertionResults.ToArray())
      rawModeBoundaryResults = @($rawModeBoundaryResults.ToArray())
      semanticEvidence = $semanticEvidence
      semanticGateOutcome = $semanticGateOutcome
      resultClass = $resultClass
      gateOutcome = $gateOutcome
      capturePath = $capturePath
      reportPath = $reportPath
    }) | Out-Null
    $knownFlagObservedScenarioName = [string]$activeScenarioName
    $knownFlagObservedCapturePath = [string]$capturePath
    $knownFlagObservedReportPath = [string]$reportPath
    $observedCapturePath = [string]$capturePath
    $observedReportPath = [string]$reportPath

    if ($semanticFailures.Count -gt 0) {
      $failureSummary = [string]::Join(
        '; ',
        @($semanticFailures | ForEach-Object {
          if ($_.PSObject.Properties['expectation']) {
            "{0}: {1}" -f [string]$_.expectation, [string]$_.details
          } else {
            "{0}: {1}" -f [string]$_.requirement, [string]$_.details
          }
        })
      )
      throw ("NI image flag scenario '{0}' failed rendered semantic assertions: {1}" -f $activeScenarioName, $failureSummary)
    }
  }
  $scenarioReportPath = Write-PrePushKnownFlagScenarioReport `
    -repoRoot $root `
    -contract $knownFlagScenarioContract `
    -observedOutcome 'pass' `
    -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $knownFlagScenarioResults) `
    -failureMessage '' `
    -activeScenarioName $knownFlagObservedScenarioName `
    -activeCapturePath $knownFlagObservedCapturePath `
    -activeReportPath $knownFlagObservedReportPath
  Write-Host ("[pre-push] Known-flag scenario report: {0}" -f $scenarioReportPath) -ForegroundColor DarkGray
  $renderingCertificationReportPath = Write-PrePushRenderingCertificationReport `
    -repoRoot $root `
    -contract $knownFlagScenarioContract `
    -observedOutcome 'pass' `
    -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $knownFlagScenarioResults) `
    -failureMessage '' `
    -activeScenarioName $knownFlagObservedScenarioName `
    -activeCapturePath $knownFlagObservedCapturePath `
    -activeReportPath $knownFlagObservedReportPath
  Write-Host ("[pre-push] Rendering certification report: {0}" -f $renderingCertificationReportPath) -ForegroundColor DarkGray

  $currentLane = 'transport-smoke'
  $activeScenarioName = 'single-container-matrix'
  $activeScenarioFlags = @()
  $scenarioDir = Join-Path $scenarioRoot $activeScenarioName
  $singleContainerResultsDir = Join-Path $scenarioDir 'matrix-results'
  New-Item -ItemType Directory -Path $singleContainerResultsDir -Force | Out-Null
  $reportPath = Join-Path $scenarioDir 'compare-report.html'
  $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
  $capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'
  $observedCapturePath = [string]$capturePath
  $observedReportPath = [string]$reportPath
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
  if ($ledgerRows.Count -ne $transportMatrixScenarios.Count) {
    throw ("NI image flag scenario '{0}' ledger count mismatch ({1} != {2})." -f $activeScenarioName, $ledgerRows.Count, $transportMatrixScenarios.Count)
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
  $expectedScenarioNames = @($transportMatrixScenarios | ForEach-Object { [string]$_.name })
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

  $transportSmokeResults.Add([pscustomobject]@{
    name = $activeScenarioName
    requestedFlags = @('all combinations')
    flags = @($flagsUsed)
    resultClass = $resultClass
    gateOutcome = $gateOutcome
    capturePath = $capturePath
    reportPath = $reportPath
  }) | Out-Null
  $transportObservedCapturePath = [string]$capturePath
  $transportObservedReportPath = [string]$reportPath
  $observedCapturePath = [string]$capturePath
  $observedReportPath = [string]$reportPath
  $transportLaneReportPath = Write-PrePushSupportLaneReport `
    -repoRoot $root `
    -reportPath $transportSmokeReportPath `
    -schema 'pre-push-ni-transport-smoke-report@v1' `
    -laneName 'single-container-matrix' `
    -description 'Transport-oriented single-container matrix smoke for NI Linux compare execution.' `
    -observedOutcome 'pass' `
    -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $transportSmokeResults) `
    -failureMessage '' `
    -capturePath $transportObservedCapturePath `
    -reportArtifactPath $transportObservedReportPath
  Write-Host ("[pre-push] Transport smoke report: {0}" -f $transportLaneReportPath) -ForegroundColor DarkGray

  $currentLane = 'vi-history-smoke'
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
  $observedCapturePath = [string]$capturePath
  $observedReportPath = [string]$reportPath
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

  $viHistorySmokeResults.Add([pscustomobject]@{
    name = $activeScenarioName
    requestedFlags = @('vi-history-suite')
    flags = @('suite-manifest', 'history-report', 'history-summary')
    resultClass = $resultClass
    gateOutcome = $gateOutcome
    capturePath = $capturePath
    reportPath = $viHistoryHtmlPath
  }) | Out-Null
  $viHistoryObservedCapturePath = [string]$capturePath
  $viHistoryObservedReportPath = [string]$viHistoryHtmlPath
  $observedCapturePath = [string]$capturePath
  $observedReportPath = [string]$viHistoryHtmlPath
  $viHistoryLaneReportPath = Write-PrePushSupportLaneReport `
    -repoRoot $root `
    -reportPath $viHistorySmokeReportPath `
    -schema 'pre-push-ni-vi-history-smoke-report@v1' `
    -laneName 'vi-history-report' `
    -description 'VI history rendering smoke lane for in-container history bundle generation.' `
    -observedOutcome 'pass' `
    -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $viHistorySmokeResults) `
    -failureMessage '' `
    -capturePath $viHistoryObservedCapturePath `
    -reportArtifactPath $viHistoryObservedReportPath
  Write-Host ("[pre-push] VI history smoke report: {0}" -f $viHistoryLaneReportPath) -ForegroundColor DarkGray

  if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
      '### Pre-push NI Image Scenarios',
      '',
      ('- activeScenarioPackId=`{0}` expectedImage=`{1}` declaredScenarios=`{2}`' -f $knownFlagScenarioPackId, $expectedImage, @($knownFlagScenarioContract.scenarios).Count),
      ''
    )
    $lines += '#### Rendering Certification'
    $lines += ('- report=`{0}` blocking=`true` scope=`pre-push`' -f $renderingCertificationReportPath)
    foreach ($scenarioResult in $knownFlagScenarioResults) {
      $reviewerPassCount = @($scenarioResult.reviewerAssertionResults | Where-Object { $_.passed }).Count
      $reviewerTotalCount = @($scenarioResult.reviewerAssertionResults).Count
      $rawBoundaryPassCount = @($scenarioResult.rawModeBoundaryResults | Where-Object { $_.passed }).Count
      $rawBoundaryTotalCount = @($scenarioResult.rawModeBoundaryResults).Count
      $lines += ('- `{0}`: semanticGateOutcome=`{1}` reviewerAssertions=`{2}/{3}` rawBoundaries=`{4}/{5}`' -f $scenarioResult.name, $scenarioResult.semanticGateOutcome, $reviewerPassCount, $reviewerTotalCount, $rawBoundaryPassCount, $rawBoundaryTotalCount)
    }
    $lines += ''
    $lines += '#### Active Scenario Pack'
    foreach ($scenarioResult in $knownFlagScenarioResults) {
      $requestedFlags = if (@($scenarioResult.requestedFlags).Count -eq 0) { '(none)' } else { [string]::Join(', ', @($scenarioResult.requestedFlags)) }
      $lines += ('- `{0}`: resultClass=`{1}` gateOutcome=`{2}` requestedFlags=`{3}` effectiveFlags=`{4}`' -f $scenarioResult.name, $scenarioResult.resultClass, $scenarioResult.gateOutcome, $requestedFlags, [string]::Join(', ', @($scenarioResult.flags)))
      $lines += ('  description=`{0}` priorityClass=`{1}` planes=`{2}`' -f $scenarioResult.description, $scenarioResult.priorityClass, [string]::Join(', ', @($scenarioResult.planeApplicability)))
      $lines += ('  capture=`{0}` report=`{1}`' -f $scenarioResult.capturePath, $scenarioResult.reportPath)
    }
    $lines += ''
    $lines += '#### Transport Smoke'
    foreach ($scenarioResult in $transportSmokeResults) {
      $requestedFlags = if (@($scenarioResult.requestedFlags).Count -eq 0) { '(none)' } else { [string]::Join(', ', @($scenarioResult.requestedFlags)) }
      $lines += ('- `{0}`: resultClass=`{1}` gateOutcome=`{2}` requestedFlags=`{3}` effectiveFlags=`{4}`' -f $scenarioResult.name, $scenarioResult.resultClass, $scenarioResult.gateOutcome, $requestedFlags, [string]::Join(', ', @($scenarioResult.flags)))
      $lines += ('  capture=`{0}` report=`{1}`' -f $scenarioResult.capturePath, $scenarioResult.reportPath)
    }
    $lines += ''
    $lines += '#### VI History Smoke'
    foreach ($scenarioResult in $viHistorySmokeResults) {
      $requestedFlags = if (@($scenarioResult.requestedFlags).Count -eq 0) { '(none)' } else { [string]::Join(', ', @($scenarioResult.requestedFlags)) }
      $lines += ('- `{0}`: resultClass=`{1}` gateOutcome=`{2}` requestedFlags=`{3}` effectiveFlags=`{4}`' -f $scenarioResult.name, $scenarioResult.resultClass, $scenarioResult.gateOutcome, $requestedFlags, [string]::Join(', ', @($scenarioResult.flags)))
      $lines += ('  capture=`{0}` report=`{1}`' -f $scenarioResult.capturePath, $scenarioResult.reportPath)
    }
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }
  Write-Host ("[pre-push] Active known-flag scenario pack '{0}' OK" -f $knownFlagScenarioPackId) -ForegroundColor Green
} catch {
  $failureMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { [string]$_ }
  switch ($currentLane) {
    'known-flag' {
      $scenarioReportPath = Write-PrePushKnownFlagScenarioReport `
        -repoRoot $root `
        -contract $knownFlagScenarioContract `
        -observedOutcome 'fail' `
        -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $knownFlagScenarioResults) `
        -failureMessage $failureMessage `
        -activeScenarioName ([string]$activeScenarioName) `
        -activeCapturePath $observedCapturePath `
        -activeReportPath $observedReportPath
      if (-not [string]::IsNullOrWhiteSpace($scenarioReportPath)) {
        Write-Host ("[pre-push] Known-flag scenario report: {0}" -f $scenarioReportPath) -ForegroundColor Yellow
      }
      $renderingCertificationReportPath = Write-PrePushRenderingCertificationReport `
        -repoRoot $root `
        -contract $knownFlagScenarioContract `
        -observedOutcome 'fail' `
        -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $knownFlagScenarioResults) `
        -failureMessage $failureMessage `
        -activeScenarioName ([string]$activeScenarioName) `
        -activeCapturePath $observedCapturePath `
        -activeReportPath $observedReportPath
      if (-not [string]::IsNullOrWhiteSpace($renderingCertificationReportPath)) {
        Write-Host ("[pre-push] Rendering certification report: {0}" -f $renderingCertificationReportPath) -ForegroundColor Yellow
      }
    }
    'transport-smoke' {
      $transportLaneReportPath = Write-PrePushSupportLaneReport `
        -repoRoot $root `
        -reportPath $transportSmokeReportPath `
        -schema 'pre-push-ni-transport-smoke-report@v1' `
        -laneName 'single-container-matrix' `
        -description 'Transport-oriented single-container matrix smoke for NI Linux compare execution.' `
        -observedOutcome 'fail' `
        -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $transportSmokeResults) `
        -failureMessage $failureMessage `
        -capturePath $observedCapturePath `
        -reportArtifactPath $observedReportPath
      if (-not [string]::IsNullOrWhiteSpace($transportLaneReportPath)) {
        Write-Host ("[pre-push] Transport smoke report: {0}" -f $transportLaneReportPath) -ForegroundColor Yellow
      }
    }
    'vi-history-smoke' {
      $viHistoryLaneReportPath = Write-PrePushSupportLaneReport `
        -repoRoot $root `
        -reportPath $viHistorySmokeReportPath `
        -schema 'pre-push-ni-vi-history-smoke-report@v1' `
        -laneName 'vi-history-report' `
        -description 'VI history rendering smoke lane for in-container history bundle generation.' `
        -observedOutcome 'fail' `
        -scenarioResults (ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $viHistorySmokeResults) `
        -failureMessage $failureMessage `
        -capturePath $observedCapturePath `
        -reportArtifactPath $observedReportPath
      if (-not [string]::IsNullOrWhiteSpace($viHistoryLaneReportPath)) {
        Write-Host ("[pre-push] VI history smoke report: {0}" -f $viHistoryLaneReportPath) -ForegroundColor Yellow
      }
    }
  }
  $eventReportPath = Write-PrePushNIKnownFlagIncidentEvent `
    -repoRoot $root `
    -errorMessage $failureMessage `
    -scenarioId $knownFlagScenarioPackId `
    -scenarioName $activeScenarioName `
    -scenarioDir $scenarioDir `
    -capturePath $capturePath `
    -expectedImage $expectedImage `
    -containerLabVIEWPath $containerLabVIEWPath `
    -scenarioFlags $activeScenarioFlags `
    -reportPath $reportPath `
    -runtimeSnapshotPath $runtimeSnapshotPath `
    -incidentInputPath $knownFlagScenarioContract.incidentInputPath `
    -incidentEventPath $knownFlagScenarioContract.incidentEventPath
  if (-not [string]::IsNullOrWhiteSpace($eventReportPath)) {
    Write-Host ("[pre-push] NI known-flag incident event report: {0}" -f $eventReportPath) -ForegroundColor Yellow
  }
  throw
}
