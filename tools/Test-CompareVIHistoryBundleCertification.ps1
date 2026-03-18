[CmdletBinding()]
param(
    [string]$TargetPath = 'VI1.vi',
    [string]$StartRef = 'HEAD',
    [string]$SourceBranchRef = 'develop',
    [ValidateRange(1, 1000)]
    [int]$MaxPairs = 1,
    [string]$Mode = 'attributes,front-panel,block-diagram',
    [string]$ResultsDir = 'tests/results/_agent/comparevi-history-bundle-certification',
    [string]$SummaryJsonPath,
    [string]$BundleArchivePath,
    [string]$BundleRoot,
    [string]$InvokeScriptPath,
    [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
    [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $PathValue).Path
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )

    $directory = Split-Path -Parent $PathValue
    if ($directory) {
        Ensure-Directory -PathValue $directory | Out-Null
    }

    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $PathValue -Encoding utf8
}

function Write-GitHubOutputValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [AllowNull()][AllowEmptyString()][string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { return }
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ($null -eq $Value) { return }
    ("{0}={1}" -f $Name, $Value) | Out-File -FilePath $DestinationPath -Encoding utf8 -Append
}

function Write-StepSummaryLines {
    param(
        [string[]]$Lines,
        [AllowNull()][AllowEmptyString()][string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { return }
    if (-not $Lines) { return }
    $Lines | Out-File -FilePath $DestinationPath -Encoding utf8 -Append
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($argument in $Arguments) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function Read-GitHubOutputFile {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    $values = @{}
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $PathValue) {
        if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
            $values[$matches['key']] = $matches['value']
        }
    }

    return $values
}

function Test-GitRefExists {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$RefName
    )

    $probe = Invoke-CapturedProcess -FilePath 'git' -Arguments @('rev-parse', '--verify', '--quiet', $RefName) -WorkingDirectory $RepoRoot
    return ($probe.ExitCode -eq 0)
}

function Resolve-SourceBranchRefForCertification {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$PreferredRef
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $trimmedPreferredRef = $PreferredRef.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmedPreferredRef)) {
        $candidates.Add($trimmedPreferredRef) | Out-Null
        if ($trimmedPreferredRef -notmatch '[/\\]') {
            $candidates.Add(("origin/{0}" -f $trimmedPreferredRef)) | Out-Null
            $candidates.Add(("refs/remotes/origin/{0}" -f $trimmedPreferredRef)) | Out-Null
            $candidates.Add(("upstream/{0}" -f $trimmedPreferredRef)) | Out-Null
            $candidates.Add(("refs/remotes/upstream/{0}" -f $trimmedPreferredRef)) | Out-Null
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-GitRefExists -RepoRoot $RepoRoot -RefName $candidate) {
            return $candidate
        }
    }

    throw "Unable to resolve a branch-like source ref for certification from '$PreferredRef'."
}

function Resolve-BundleRoot {
    param(
        [AllowNull()][AllowEmptyString()][string]$BundleArchivePath,
        [AllowNull()][AllowEmptyString()][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$ResultsRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($BundleArchivePath) -and -not [string]::IsNullOrWhiteSpace($BundleRoot)) {
        throw 'Specify either -BundleArchivePath or -BundleRoot, not both.'
    }

    if (-not [string]::IsNullOrWhiteSpace($BundleArchivePath)) {
        $archivePath = Resolve-FullPath -PathValue $BundleArchivePath -BasePath $RepoRoot
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw "Bundle archive not found: $archivePath"
        }

        $expandRoot = Ensure-Directory -PathValue (Join-Path $ResultsRoot 'bundle')
        $existingEntries = Get-ChildItem -LiteralPath $expandRoot -Force -ErrorAction SilentlyContinue
        foreach ($entry in $existingEntries) {
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $expandRoot -Force
        $bundleDirectories = @(Get-ChildItem -LiteralPath $expandRoot -Directory)
        if ($bundleDirectories.Count -ne 1) {
            throw "Expected one extracted bundle directory under $expandRoot but found $($bundleDirectories.Count)."
        }

        return [pscustomobject]@{
            BundleRoot = $bundleDirectories[0].FullName
            BundleArchivePath = $archivePath
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BundleRoot)) {
        $resolvedBundleRoot = Resolve-FullPath -PathValue $BundleRoot -BasePath $RepoRoot
        if (-not (Test-Path -LiteralPath $resolvedBundleRoot -PathType Container)) {
            throw "Bundle root not found: $resolvedBundleRoot"
        }

        return [pscustomobject]@{
            BundleRoot = $resolvedBundleRoot
            BundleArchivePath = $null
        }
    }

    return [pscustomobject]@{
        BundleRoot = $RepoRoot
        BundleArchivePath = $null
    }
}

function Ensure-NonShallowGitHistory {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $probe = Invoke-CapturedProcess -FilePath 'git' -Arguments @('rev-parse', '--is-shallow-repository') -WorkingDirectory $RepoRoot
    if ($probe.ExitCode -ne 0) {
        throw "Unable to determine git shallow state: $($probe.StdErr.Trim())"
    }

    $isShallow = $probe.StdOut.Trim()
    if ($isShallow -ne 'true') {
        return
    }

    $fetch = Invoke-CapturedProcess -FilePath 'git' -Arguments @('fetch', '--unshallow', '--tags', 'origin') -WorkingDirectory $RepoRoot
    if ($fetch.ExitCode -ne 0) {
        throw "Failed to unshallow repository history for certification: $($fetch.StdErr.Trim())"
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resultsRoot = Ensure-Directory -PathValue (Resolve-FullPath -PathValue $ResultsDir -BasePath $repoRoot)
$historyResultsDir = Ensure-Directory -PathValue (Join-Path $resultsRoot 'history')
$summaryPath = if ([string]::IsNullOrWhiteSpace($SummaryJsonPath)) {
    Join-Path $resultsRoot 'comparevi-history-bundle-certification.json'
} else {
    Resolve-FullPath -PathValue $SummaryJsonPath -BasePath $repoRoot
}
$historyGitHubOutputPath = Join-Path $resultsRoot 'comparevi-history-bundle-github-output.txt'
$historyStepSummaryPath = if ([string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    Join-Path $resultsRoot 'comparevi-history-bundle-step-summary.md'
} else {
    Resolve-FullPath -PathValue $StepSummaryPath -BasePath $repoRoot
}
$stdoutPath = Join-Path $resultsRoot 'comparevi-history-bundle-stdout.txt'
$stderrPath = Join-Path $resultsRoot 'comparevi-history-bundle-stderr.txt'

$bundleResolution = Resolve-BundleRoot -BundleArchivePath $BundleArchivePath -BundleRoot $BundleRoot -ResultsRoot $resultsRoot -RepoRoot $repoRoot
$executionRoot = [string]$bundleResolution.BundleRoot
$executionMode = if ([string]::Equals($executionRoot, $repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    'repo-source'
} else {
    'bundle'
}

foreach ($stalePath in @($historyGitHubOutputPath, $stdoutPath, $stderrPath)) {
    if (Test-Path -LiteralPath $stalePath -PathType Leaf) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

Ensure-NonShallowGitHistory -RepoRoot $repoRoot

$fixtureMap = [ordered]@{
    attributes = Join-Path $repoRoot 'fixtures' 'vi-report' 'vi-attribute'
    'front-panel' = Join-Path $repoRoot 'fixtures' 'vi-report' 'front-panel'
    'block-diagram' = Join-Path $repoRoot 'fixtures' 'vi-report' 'block-diagram'
}

$historyScriptPath = Join-Path $executionRoot 'tools' 'Compare-VIHistory.ps1'
$stubPath = if ([string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
    Join-Path $repoRoot 'tests' 'stubs' 'Invoke-LVCompare.stub.ps1'
} else {
    Resolve-FullPath -PathValue $InvokeScriptPath -BasePath $repoRoot
}

if (-not (Test-Path -LiteralPath $historyScriptPath -PathType Leaf)) {
    throw "Compare-VIHistory.ps1 not found: $historyScriptPath"
}
if (-not (Test-Path -LiteralPath $stubPath -PathType Leaf)) {
    throw "Shared history smoke stub not found: $stubPath"
}

$historyScriptCommand = Get-Command $historyScriptPath -ErrorAction Stop
$historyScriptSupportsSourceBranchRef = $historyScriptCommand.Parameters.ContainsKey('SourceBranchRef')
if (-not $historyScriptSupportsSourceBranchRef) {
    throw "Compare-VIHistory bundle contract is missing -SourceBranchRef support: $historyScriptPath"
}
$effectiveSourceBranchRef = Resolve-SourceBranchRefForCertification -RepoRoot $repoRoot -PreferredRef $SourceBranchRef

$previousModeFixtureMap = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_MODE_FIXTURE_MAP_JSON', 'Process')
$previousExplicitFixture = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_REPORT_FIXTURE', 'Process')
$previousStubRepoRoot = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_REPO_ROOT', 'Process')

try {
    [System.Environment]::SetEnvironmentVariable('STUB_COMPARE_MODE_FIXTURE_MAP_JSON', ($fixtureMap | ConvertTo-Json -Depth 4 -Compress), 'Process')
    [System.Environment]::SetEnvironmentVariable('STUB_COMPARE_REPORT_FIXTURE', $null, 'Process')
    [System.Environment]::SetEnvironmentVariable('STUB_COMPARE_REPO_ROOT', $repoRoot, 'Process')

    $sourceBranchMaxCommitCount = 1000
    $historyResult = Invoke-CapturedProcess -FilePath 'pwsh' -Arguments @(
        '-NoLogo',
        '-NoProfile',
        '-File', $historyScriptPath,
        '-TargetPath', $TargetPath,
        '-StartRef', $StartRef,
        '-SourceBranchRef', $effectiveSourceBranchRef,
        '-MaxBranchCommits', [string]$sourceBranchMaxCommitCount,
        '-MaxPairs', [string]$MaxPairs,
        '-NoisePolicy', 'collapse',
        '-Mode', $Mode,
        '-ResultsDir', $historyResultsDir,
        '-InvokeScriptPath', $stubPath,
        '-Detailed',
        '-RenderReport',
        '-GitHubOutputPath', $historyGitHubOutputPath,
        '-StepSummaryPath', $historyStepSummaryPath
    ) -WorkingDirectory $repoRoot
} finally {
    [System.Environment]::SetEnvironmentVariable('STUB_COMPARE_MODE_FIXTURE_MAP_JSON', $previousModeFixtureMap, 'Process')
    [System.Environment]::SetEnvironmentVariable('STUB_COMPARE_REPORT_FIXTURE', $previousExplicitFixture, 'Process')
    [System.Environment]::SetEnvironmentVariable('STUB_COMPARE_REPO_ROOT', $previousStubRepoRoot, 'Process')
}

$historyResult.StdOut | Set-Content -LiteralPath $stdoutPath -Encoding utf8
$historyResult.StdErr | Set-Content -LiteralPath $stderrPath -Encoding utf8

if ($historyResult.ExitCode -ne 0) {
    throw "Compare-VIHistory certification run failed with exit code $($historyResult.ExitCode). See $stdoutPath and $stderrPath."
}

$historyOutputs = Read-GitHubOutputFile -PathValue $historyGitHubOutputPath
$aggregateManifestPath = if ($historyOutputs.ContainsKey('manifest-path')) {
    [string]$historyOutputs['manifest-path']
} else {
    Join-Path $historyResultsDir 'manifest.json'
}
$historyReportMd = if ($historyOutputs.ContainsKey('history-report-md')) { [string]$historyOutputs['history-report-md'] } else { Join-Path $historyResultsDir 'history-report.md' }
$historyReportHtml = if ($historyOutputs.ContainsKey('history-report-html')) { [string]$historyOutputs['history-report-html'] } else { Join-Path $historyResultsDir 'history-report.html' }
$historySummaryJson = if ($historyOutputs.ContainsKey('history-summary-json')) { [string]$historyOutputs['history-summary-json'] } else { Join-Path $historyResultsDir 'history-summary.json' }

if (-not (Test-Path -LiteralPath $aggregateManifestPath -PathType Leaf)) {
    throw "Aggregate certification manifest was not produced: $aggregateManifestPath"
}
if (-not (Test-Path -LiteralPath $historySummaryJson -PathType Leaf)) {
    throw "History facade summary was not produced: $historySummaryJson"
}

$aggregateManifest = Get-Content -LiteralPath $aggregateManifestPath -Raw | ConvertFrom-Json -Depth 12
$historySummary = Get-Content -LiteralPath $historySummaryJson -Raw | ConvertFrom-Json -Depth 12
$expectedModes = @('attributes', 'front-panel', 'block-diagram')
$actualModes = @($aggregateManifest.modes | ForEach-Object { [string]$_.slug })
$missingModes = @($expectedModes | Where-Object { $actualModes -notcontains $_ })
$unexpectedModes = @($actualModes | Where-Object { $expectedModes -notcontains $_ })

$warningLine = @(
    $historyResult.StdOut -split "`r?`n"
    $historyResult.StdErr -split "`r?`n"
) | Where-Object { $_ -match 'LVCompare detected differences' } | Select-Object -First 1

$modeSummaries = @()
$unspecifiedHits = New-Object System.Collections.Generic.List[string]
foreach ($modeEntry in @($aggregateManifest.modes)) {
    $modeManifestPath = [string]$modeEntry.manifestPath
    if (-not (Test-Path -LiteralPath $modeManifestPath -PathType Leaf)) {
        throw "Per-mode manifest missing for certification: $modeManifestPath"
    }

    $modeManifest = Get-Content -LiteralPath $modeManifestPath -Raw | ConvertFrom-Json -Depth 12
    $modeSummary = [ordered]@{
        name = [string]$modeEntry.name
        slug = [string]$modeEntry.slug
        manifestPath = $modeManifestPath
        status = [string]$modeManifest.status
        flags = @($modeManifest.flags)
        processed = [int]$modeManifest.stats.processed
        diffs = [int]$modeManifest.stats.diffs
        signalDiffs = [int]$modeManifest.stats.signalDiffs
        noiseCollapsed = [int]$modeManifest.stats.noiseCollapsed
        stopReason = [string]$modeManifest.stats.stopReason
        categoryCounts = $modeManifest.stats.categoryCounts
        bucketCounts = $modeManifest.stats.bucketCounts
        collapsedNoise = [ordered]@{
            count = [int]$modeManifest.stats.collapsedNoise.count
            categoryCounts = $modeManifest.stats.collapsedNoise.categoryCounts
            bucketCounts = $modeManifest.stats.collapsedNoise.bucketCounts
        }
    }

    foreach ($candidateMap in @($modeManifest.stats.categoryCounts, $modeManifest.stats.collapsedNoise.categoryCounts)) {
        if (-not $candidateMap) { continue }
        foreach ($property in $candidateMap.PSObject.Properties) {
            if ([string]::Equals([string]$property.Name, 'unspecified', [System.StringComparison]::OrdinalIgnoreCase)) {
                $unspecifiedHits.Add(("{0}:{1}" -f $modeEntry.slug, $property.Name)) | Out-Null
            }
        }
    }

    $modeSummaries += [pscustomobject]$modeSummary
}

if ($aggregateManifest.stats.categoryCounts) {
    foreach ($property in $aggregateManifest.stats.categoryCounts.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, 'unspecified', [System.StringComparison]::OrdinalIgnoreCase)) {
            $unspecifiedHits.Add(("aggregate:{0}" -f $property.Name)) | Out-Null
        }
    }
}

$warningHasUnspecified = -not [string]::IsNullOrWhiteSpace($warningLine) -and ($warningLine -match '(?i)unspecified')
$warningHasExplicitCategories = -not [string]::IsNullOrWhiteSpace($warningLine) -and ($warningLine -match '(?i)vi attribute|front panel|block diagram')
$summaryRequestedModes = @($historySummary.execution.requestedModes | ForEach-Object { [string]$_ })
$summaryExecutedModes = @($historySummary.execution.executedModes | ForEach-Object { [string]$_ })
$summaryModeSlugs = @($historySummary.modes | ForEach-Object { [string]$_.slug })
$summaryCoverageClass = [string]$historySummary.observedInterpretation.coverageClass
$summarySchemaMatches = [string]$historySummary.schema -eq 'comparevi-tools/history-facade@v1'
$summaryRequestedMatches = (($summaryRequestedModes.Count -eq $expectedModes.Count) -and (@($summaryRequestedModes | Where-Object { $expectedModes -notcontains $_ }).Count -eq 0))
$summaryExecutedMatches = (($summaryExecutedModes.Count -eq $expectedModes.Count) -and (@($summaryExecutedModes | Where-Object { $expectedModes -notcontains $_ }).Count -eq 0))
$summaryModeListMatches = (($summaryModeSlugs.Count -eq $expectedModes.Count) -and (@($summaryModeSlugs | Where-Object { $expectedModes -notcontains $_ }).Count -eq 0))
$summaryCoverageAligned = $summaryCoverageClass -eq 'catalog-aligned'
$summarySourceBranchRef = [string]$historySummary.target.sourceBranchRef
$summarySourceBranchRefMatches = [string]::Equals($summarySourceBranchRef, $effectiveSourceBranchRef, [System.StringComparison]::Ordinal)
$passed = ($missingModes.Count -eq 0) -and ($unexpectedModes.Count -eq 0) -and ($unspecifiedHits.Count -eq 0) -and (-not $warningHasUnspecified) -and $warningHasExplicitCategories -and $summarySchemaMatches -and $summaryRequestedMatches -and $summaryExecutedMatches -and $summaryModeListMatches -and $summaryCoverageAligned -and $historyScriptSupportsSourceBranchRef -and $summarySourceBranchRefMatches

if (-not $warningLine) {
    throw 'Certification run did not emit an LVCompare detected differences warning line.'
}

if (-not $passed) {
    $failureReasons = New-Object System.Collections.Generic.List[string]
    if ($missingModes.Count -gt 0) {
        $failureReasons.Add(("missing modes: {0}" -f ($missingModes -join ', '))) | Out-Null
    }
    if ($unexpectedModes.Count -gt 0) {
        $failureReasons.Add(("unexpected modes: {0}" -f ($unexpectedModes -join ', '))) | Out-Null
    }
    if ($unspecifiedHits.Count -gt 0) {
        $failureReasons.Add(("unspecified categories: {0}" -f ($unspecifiedHits -join ', '))) | Out-Null
    }
    if ($warningHasUnspecified) {
        $failureReasons.Add('warning line still includes unspecified') | Out-Null
    }
    if (-not $warningHasExplicitCategories) {
        $failureReasons.Add('warning line did not include explicit category labels') | Out-Null
    }
    if (-not $summarySchemaMatches) {
        $failureReasons.Add('history facade schema mismatch') | Out-Null
    }
    if (-not $summaryRequestedMatches) {
        $failureReasons.Add(("history facade requested modes mismatch: {0}" -f ($summaryRequestedModes -join ', '))) | Out-Null
    }
    if (-not $summaryExecutedMatches) {
        $failureReasons.Add(("history facade executed modes mismatch: {0}" -f ($summaryExecutedModes -join ', '))) | Out-Null
    }
    if (-not $summaryModeListMatches) {
        $failureReasons.Add(("history facade mode list mismatch: {0}" -f ($summaryModeSlugs -join ', '))) | Out-Null
    }
    if (-not $summaryCoverageAligned) {
        $failureReasons.Add(("history facade coverage class mismatch: {0}" -f $summaryCoverageClass)) | Out-Null
    }
    if (-not $historyScriptSupportsSourceBranchRef) {
        $failureReasons.Add('history script missing SourceBranchRef parameter') | Out-Null
    }
    if (-not $summarySourceBranchRefMatches) {
        $failureReasons.Add(("history facade sourceBranchRef mismatch: expected {0} actual {1}" -f $effectiveSourceBranchRef, $summarySourceBranchRef)) | Out-Null
    }
    throw ("Multi-mode history bundle certification failed: {0}" -f ($failureReasons -join '; '))
}

$summaryObject = [ordered]@{
    schema = 'comparevi-history-bundle-certification@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    targetPath = $TargetPath
    startRef = $StartRef
    sourceBranchRef = $effectiveSourceBranchRef
    maxPairs = [int]$MaxPairs
    requestedMode = $Mode
    resultsDir = $historyResultsDir
    execution = [ordered]@{
        mode = $executionMode
        repoRoot = $repoRoot
        bundleRoot = $executionRoot
        bundleArchivePath = $bundleResolution.BundleArchivePath
        historyScriptPath = $historyScriptPath
        historyScriptSupportsSourceBranchRef = $historyScriptSupportsSourceBranchRef
        invokeScriptPath = $stubPath
    }
    outputs = [ordered]@{
        aggregateManifestPath = $aggregateManifestPath
        historySummaryJson = $historySummaryJson
        historyReportMd = $historyReportMd
        historyReportHtml = $historyReportHtml
        historyGitHubOutputPath = $historyGitHubOutputPath
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        stepSummaryPath = $historyStepSummaryPath
    }
    aggregate = [ordered]@{
        processed = [int]$aggregateManifest.stats.processed
        diffs = [int]$aggregateManifest.stats.diffs
        signalDiffs = [int]$aggregateManifest.stats.signalDiffs
        noiseCollapsed = [int]$aggregateManifest.stats.noiseCollapsed
        categoryCounts = $aggregateManifest.stats.categoryCounts
        bucketCounts = $aggregateManifest.stats.bucketCounts
    }
    historyFacade = [ordered]@{
        schema = [string]$historySummary.schema
        requestedModes = $summaryRequestedModes
        executedModes = $summaryExecutedModes
        sourceBranchRef = $summarySourceBranchRef
        coverageClass = $summaryCoverageClass
        outcomeLabels = @($historySummary.observedInterpretation.outcomeLabels)
    }
    warningText = $warningLine
    modes = $modeSummaries
    certification = [ordered]@{
        expectedModes = $expectedModes
        actualModes = $actualModes
        missingModes = $missingModes
        unexpectedModes = $unexpectedModes
        noUnspecified = ($unspecifiedHits.Count -eq 0)
        warningHasUnspecified = $warningHasUnspecified
        warningHasExplicitCategories = $warningHasExplicitCategories
        historyFacadeSchemaMatches = $summarySchemaMatches
        historyFacadeRequestedModesMatch = $summaryRequestedMatches
        historyFacadeExecutedModesMatch = $summaryExecutedMatches
        historyFacadeModeListMatch = $summaryModeListMatches
        historyFacadeCoverageAligned = $summaryCoverageAligned
        historyScriptSupportsSourceBranchRef = $historyScriptSupportsSourceBranchRef
        historyFacadeSourceBranchRefMatches = $summarySourceBranchRefMatches
        passed = $true
    }
}
Write-JsonFile -PathValue $summaryPath -Value $summaryObject

$summaryLines = @()
$summaryLines += ''
$summaryLines += '## CompareVI History Bundle Certification'
$summaryLines += ''
$summaryLines += ('- Execution: `{0}`' -f $executionMode)
$summaryLines += ('- History script: `{0}`' -f $historyScriptPath)
$summaryLines += ('- Source branch: `{0}`' -f $effectiveSourceBranchRef)
$summaryLines += ('- History script supports `-SourceBranchRef`: `{0}`' -f $historyScriptSupportsSourceBranchRef.ToString().ToLowerInvariant())
$summaryLines += ('- Modes: `{0}`' -f ($actualModes -join ', '))
$summaryLines += ('- Warning: `{0}`' -f $warningLine)
$summaryLines += ('- Summary JSON: `{0}`' -f $summaryPath)
$summaryLines += ('- Aggregate manifest: `{0}`' -f $aggregateManifestPath)
$summaryLines += ('- History facade JSON: `{0}`' -f $historySummaryJson)
$summaryLines += ('- History facade coverage: `{0}`' -f $summaryCoverageClass)
$summaryLines += ''
$summaryLines += '| Mode | Processed | Diffs | Signal | Collapsed Noise | Stop Reason |'
$summaryLines += '| --- | ---: | ---: | ---: | ---: | --- |'
foreach ($modeSummary in $modeSummaries) {
    $summaryLines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f `
        $modeSummary.slug,
        $modeSummary.processed,
        $modeSummary.diffs,
        $modeSummary.signalDiffs,
        $modeSummary.noiseCollapsed,
        $modeSummary.stopReason)
}
Write-StepSummaryLines -Lines $summaryLines -DestinationPath $historyStepSummaryPath

Write-GitHubOutputValue -Name 'summary-json-path' -Value $summaryPath -DestinationPath $GitHubOutputPath
Write-GitHubOutputValue -Name 'results-dir' -Value $historyResultsDir -DestinationPath $GitHubOutputPath
Write-GitHubOutputValue -Name 'warning-text' -Value $warningLine -DestinationPath $GitHubOutputPath
Write-GitHubOutputValue -Name 'mode-list' -Value ($actualModes -join ',') -DestinationPath $GitHubOutputPath
Write-GitHubOutputValue -Name 'source-branch-ref' -Value $effectiveSourceBranchRef -DestinationPath $GitHubOutputPath

Write-Output $summaryPath
