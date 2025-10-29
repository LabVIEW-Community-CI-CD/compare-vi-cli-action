#Requires -Version 7.0
<#
.SYNOPSIS
  Runs Compare-VIHistory for each VI referenced in a diff manifest.

.DESCRIPTION
  Loads a `vi-diff-manifest@v1` payload (typically produced by
  `tools/Get-PRVIDiffManifest.ps1`), deduplicates the referenced VI paths, and
  invokes `tools/Compare-VIHistory.ps1` for each unique target. Summary
  metadata and report locations are captured in `pr-vi-history-summary@v1`
  format so PR workflows can surface Markdown tables and artifact links.

.PARAMETER ManifestPath
  Path to the diff manifest JSON file.

.PARAMETER ResultsRoot
  Directory where Compare-VIHistory outputs should be written (one subdirectory
  per VI). Defaults to `tests/results/pr-vi-history`.

.PARAMETER MaxPairs
  Maximum commit pairs to evaluate per VI (default: 5; pass 0 for no limit).

.PARAMETER Mode
  Optional Compare-VIHistory mode list (for example `default`, `attributes`).
  Forwarded directly to the history helper.

.PARAMETER SkipRenderReport
  When present, do not request the Markdown/HTML report from Compare-VIHistory.

.PARAMETER DryRun
  Emit the planned targets without invoking Compare-VIHistory.

.PARAMETER CompareInvoker
  Internal testing hook allowing callers to supply a custom script block. The
  block receives a hashtable of parameters compatible with Compare-VIHistory.

.PARAMETER SummaryPath
  Optional override for the summary JSON path. Defaults to
  `<ResultsRoot>/vi-history-summary.json`.

.PARAMETER StartRef
  Optional Compare-VIHistory `-StartRef` override.

.PARAMETER EndRef
  Optional Compare-VIHistory `-EndRef` override.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [string]$ResultsRoot = 'tests/results/pr-vi-history',

    [int]$MaxPairs = 5,

    [string[]]$Mode,

    [switch]$SkipRenderReport,

    [switch]$DryRun,

    [scriptblock]$CompareInvoker,

    [string]$SummaryPath,

    [string]$StartRef,

    [string]$EndRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description path not provided."
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-GitRepoRoot {
    $output = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        throw 'Unable to determine git repository root.'
    }
    return $output.Trim()
}

function Resolve-ViPath {
    param(
        [string]$Path,
        [string]$ParameterName,
        [switch]$AllowMissing,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        try {
            return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        } catch {
            if ($AllowMissing) {
                Write-Verbose ("Path not found for {0}: {1}" -f $ParameterName, $Path)
                return $null
            }
            throw ("Unable to resolve {0} path: {1}" -f $ParameterName, $Path)
        }
    }

    $normalized = $Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $candidate = Join-Path $RepoRoot $normalized
    try {
        return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    } catch {
        if ($AllowMissing) {
            Write-Verbose ("Path not found for {0}: {1}" -f $ParameterName, $candidate)
            return $null
        }
        throw ("Unable to resolve {0} path: {1}" -f $ParameterName, $candidate)
    }
}

function Get-HistoryFlagList {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $segments = $Raw -split "(\r\n|\n|\r)"
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $segments) {
        $candidate = $segment.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $result.Add($candidate)
    }
    return $result.ToArray()
}

function ConvertTo-NullableBool {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim().ToLowerInvariant()
    $truthy = @('1','true','yes','on','replace')
    $falsy  = @('0','false','no','off','append')
    if ($truthy -contains $normalized) { return $true }
    if ($falsy -contains $normalized) { return $false }
    return $null
}

$historyFlagList = $null
$historyFlagSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_FLAGS', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_FLAGS', 'Process')
)
foreach ($rawFlags in $historyFlagSources) {
    if ([string]::IsNullOrWhiteSpace($rawFlags)) { continue }
    $parsedFlags = [string[]](Get-HistoryFlagList -Raw $rawFlags)
    if ($parsedFlags -and $parsedFlags.Length -gt 0) {
        $historyFlagList = $parsedFlags
        break
    }
}

$historyFlagMode = $null
$historyModeSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_FLAGS_MODE', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_FLAGS_MODE', 'Process')
)
foreach ($rawMode in $historyModeSources) {
    if ([string]::IsNullOrWhiteSpace($rawMode)) { continue }
    $normalized = $rawMode.Trim().ToLowerInvariant()
    if ($normalized -eq 'replace' -or $normalized -eq 'append') {
        $historyFlagMode = $normalized
        break
    }
}

$historyReplaceOverride = $null
$historyReplaceSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_REPLACE_FLAGS', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_REPLACE_FLAGS', 'Process')
)
foreach ($rawReplace in $historyReplaceSources) {
    if ([string]::IsNullOrWhiteSpace($rawReplace)) { continue }
    $converted = ConvertTo-NullableBool -Value $rawReplace
    if ($converted -ne $null) {
        $historyReplaceOverride = $converted
        break
    }
}

$historyReplaceFlags = $null
if ($historyReplaceOverride -ne $null) {
    $historyReplaceFlags = $historyReplaceOverride
} elseif ($historyFlagMode) {
    $historyReplaceFlags = ($historyFlagMode -eq 'replace')
}

$historyFlagString = $null
if ($historyFlagList -and $historyFlagList.Length -gt 0) {
    $historyFlagString = ($historyFlagList -join ' ')
}

function Get-RepoRelativePath {
    param(
        [string]$FullPath,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        return $null
    }

    try {
        $full = [System.IO.Path]::GetFullPath($FullPath)
        $root = [System.IO.Path]::GetFullPath($RepoRoot)
    } catch {
        return $null
    }

    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $full.Substring($root.Length).TrimStart('\','/')
    if (-not $relative) {
        return $null
    }
    return $relative.Replace('\','/')
}

function Sanitize-Token {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'vi-history'
    }
    $token = ($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($token)) {
        return 'vi-history'
    }
    if ($token.Length -gt 60) {
        return $token.Substring(0, 60)
    }
    return $token
}

$resolvedManifest = Resolve-ExistingFile -Path $ManifestPath -Description 'Manifest'
$manifestRaw = Get-Content -LiteralPath $resolvedManifest -Raw -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($manifestRaw)) {
    throw "Manifest file is empty: $resolvedManifest"
}

try {
    $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw ("Manifest is not valid JSON: {0}" -f $_.Exception.Message)
}

if ($manifest.schema -ne 'vi-diff-manifest@v1') {
    throw ("Unexpected manifest schema '{0}'. Expected 'vi-diff-manifest@v1'." -f $manifest.schema)
}

$repoRoot = Get-GitRepoRoot
$pairs = @()
if ($manifest.pairs -is [System.Collections.IEnumerable]) {
    $pairs = @($manifest.pairs)
}

$targetMap = [ordered]@{}
$skippedPairs = [System.Collections.Generic.List[object]]::new()

foreach ($pair in $pairs) {
    if (-not $pair) { continue }
    $basePathRaw = if ($pair.PSObject.Properties['basePath']) { [string]$pair.basePath } else { $null }
    $headPathRaw = if ($pair.PSObject.Properties['headPath']) { [string]$pair.headPath } else { $null }
    $changeType = if ($pair.PSObject.Properties['changeType']) { [string]$pair.changeType } else { 'unknown' }

    $headResolved = Resolve-ViPath -Path $headPathRaw -ParameterName 'headPath' -AllowMissing -RepoRoot $repoRoot
    $baseResolved = Resolve-ViPath -Path $basePathRaw -ParameterName 'basePath' -AllowMissing -RepoRoot $repoRoot

    $chosenResolved = $headResolved
    $chosenLabel = $headPathRaw
    $chosenOrigin = 'head'

    if (-not $chosenResolved) {
        $chosenResolved = $baseResolved
        $chosenLabel = $basePathRaw
        $chosenOrigin = 'base'
    }

    if (-not $chosenResolved) {
        [void]$skippedPairs.Add([pscustomobject]@{
            changeType = $changeType
            basePath   = $basePathRaw
            headPath   = $headPathRaw
            reason     = 'missing-path'
        }) | Out-Null
        continue
    }

    $repoRelative = Get-RepoRelativePath -FullPath $chosenResolved -RepoRoot $repoRoot
    if (-not $repoRelative) {
        $repoRelative = $chosenLabel
    }
    if ([string]::IsNullOrWhiteSpace($repoRelative)) {
        $repoRelative = $chosenResolved
    }

    $key = $repoRelative.ToLowerInvariant()
    if (-not $targetMap.Contains($key)) {
        $entry = [ordered]@{
            repoPath     = $repoRelative
            fullPath     = $chosenResolved
            changeTypes  = [System.Collections.Generic.List[string]]::new()
            basePaths    = [System.Collections.Generic.List[string]]::new()
            headPaths    = [System.Collections.Generic.List[string]]::new()
            pairs        = [System.Collections.Generic.List[object]]::new()
            origin       = $chosenOrigin
        }
        $targetMap[$key] = $entry
    } else {
        $entry = $targetMap[$key]
        if ($entry.origin -ne 'head' -and $chosenOrigin -eq 'head') {
            $entry.origin = 'head'
            $entry.fullPath = $chosenResolved
            $entry.repoPath = $repoRelative
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($changeType) -and -not $entry.changeTypes.Contains($changeType)) {
        [void]$entry.changeTypes.Add($changeType)
    }
    if ($basePathRaw -and -not $entry.basePaths.Contains($basePathRaw)) {
        [void]$entry.basePaths.Add($basePathRaw)
    }
    if ($headPathRaw -and -not $entry.headPaths.Contains($headPathRaw)) {
        [void]$entry.headPaths.Add($headPathRaw)
    }
    [void]$entry.pairs.Add([pscustomobject]@{
        changeType = $changeType
        basePath   = $basePathRaw
        headPath   = $headPathRaw
    }) | Out-Null
}

$targets = @($targetMap.Values)

if ($DryRun.IsPresent) {
    if ($targets.Count -eq 0) {
        Write-Host 'No VI targets resolved from manifest.'
    } else {
        Write-Host 'VI history plan:'
        $rows = $targets | ForEach-Object {
            [pscustomobject]@{
                RepoPath   = $_.repoPath
                ChangeType = [string]::Join(', ', $_.changeTypes)
                Source     = $_.origin
            }
        }
        $rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
    }
    return
}

if ($targets.Count -eq 0 -and $skippedPairs.Count -eq 0) {
    Write-Host 'No VI targets to process; exiting.'
    return
}

$resultsRootResolved = if ([System.IO.Path]::IsPathRooted($ResultsRoot)) {
    $ResultsRoot
} else {
    Join-Path $repoRoot $ResultsRoot
}
New-Item -ItemType Directory -Force -Path $resultsRootResolved | Out-Null
$resultsRootResolved = (Resolve-Path -LiteralPath $resultsRootResolved).Path

$effectiveSummaryPath = if ($SummaryPath) {
    if ([System.IO.Path]::IsPathRooted($SummaryPath)) { $SummaryPath } else { Join-Path $repoRoot $SummaryPath }
} else {
    Join-Path $resultsRootResolved 'vi-history-summary.json'
}

$compareScriptPathCandidate = Join-Path (Split-Path -Parent $PSCommandPath) 'Compare-VIHistory.ps1'
try {
    $compareScriptPathResolved = (Resolve-Path -LiteralPath $compareScriptPathCandidate -ErrorAction Stop).ProviderPath
} catch {
    throw ("Unable to locate Compare-VIHistory.ps1 at expected path: {0}" -f $compareScriptPathCandidate)
}
Write-Verbose ("Compare-VIHistory resolved to: {0}" -f $compareScriptPathResolved)

if (-not $CompareInvoker) {
    $compareScriptLiteral = $compareScriptPathResolved.Replace("'", "''")
    $compareInvokerSource = @"
param([hashtable]`$Arguments)
& '$compareScriptLiteral' @Arguments
"@
    $CompareInvoker = [scriptblock]::Create($compareInvokerSource)
}

$summaryTargets = [System.Collections.Generic.List[object]]::new()
$errorTargets = [System.Collections.Generic.List[object]]::new()
$totalComparisons = 0
$totalDiffs = 0
$completedCount = 0
$diffTargetCount = 0

for ($i = 0; $i -lt $targets.Count; $i++) {
    $target = $targets[$i]
    $targetFullPath = $target.fullPath
    $repoPath = $target.repoPath
    $sanitized = Sanitize-Token -Value $repoPath
    $targetDirName = ('{0:D2}-{1}' -f ($i + 1), $sanitized)
    $targetResultsDir = Join-Path $resultsRootResolved $targetDirName
    New-Item -ItemType Directory -Force -Path $targetResultsDir | Out-Null

    $effectiveTargetPath = $targetFullPath
    if (-not [string]::IsNullOrWhiteSpace($repoPath) -and -not [System.IO.Path]::IsPathRooted($repoPath)) {
        $effectiveTargetPath = $repoPath
    }

    $compareArgs = @{
        TargetPath = $effectiveTargetPath
        ResultsDir = $targetResultsDir
        OutPrefix  = $sanitized
    }
    Write-Verbose ("[{0}/{1}] Target '{2}' (origin: {3}) -> compare path '{4}'" -f ($i + 1), $targets.Count, $repoPath, $target.origin, $effectiveTargetPath)
    if ($MaxPairs -gt 0) { $compareArgs.MaxPairs = $MaxPairs }
    if ($Mode) { $compareArgs.Mode = $Mode }
    if (-not [string]::IsNullOrWhiteSpace($StartRef)) { $compareArgs.StartRef = $StartRef }
    if (-not [string]::IsNullOrWhiteSpace($EndRef)) { $compareArgs.EndRef = $EndRef }
    if (-not $SkipRenderReport.IsPresent) { $compareArgs.RenderReport = $true }

    $compareArgs.FlagNoAttr = $false
    $compareArgs.FlagNoFp = $false
    $compareArgs.FlagNoFpPos = $false
    $compareArgs.FlagNoBdCosm = $false
    $compareArgs.ForceNoBd = $false

    if ($historyReplaceFlags -eq $true) {
        $compareArgs.ReplaceFlags = $true
        if ($historyFlagString) {
            $compareArgs.LvCompareArgs = $historyFlagString
        }
    } elseif ($historyReplaceFlags -eq $false) {
        if ($historyFlagString) {
            $compareArgs.AdditionalFlags = $historyFlagString
        }
    } elseif ($historyFlagString) {
        $compareArgs.ReplaceFlags = $true
        $compareArgs.LvCompareArgs = $historyFlagString
    }

    try {
        & $CompareInvoker $compareArgs | Out-Null
    } catch {
        $caughtError = $_
        [void]$errorTargets.Add([pscustomobject]@{
            repoPath = $repoPath
            message  = $caughtError.Exception.Message
        }) | Out-Null
        [void]$summaryTargets.Add([pscustomobject]@{
            repoPath    = $repoPath
            status      = 'error'
            message     = $caughtError.Exception.Message
            changeTypes = $target.changeTypes.ToArray()
            basePaths   = $target.basePaths.ToArray()
            headPaths   = $target.headPaths.ToArray()
            resultsDir  = $targetResultsDir
        }) | Out-Null
        continue
    }

    $manifestPath = Join-Path $targetResultsDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $errorMessage = "manifest.json not produced for $repoPath"
        [void]$errorTargets.Add([pscustomobject]@{
            repoPath = $repoPath
            message  = $errorMessage
        }) | Out-Null
        [void]$summaryTargets.Add([pscustomobject]@{
            repoPath    = $repoPath
            status      = 'error'
            message     = $errorMessage
            changeTypes = $target.changeTypes.ToArray()
            basePaths   = $target.basePaths.ToArray()
            headPaths   = $target.headPaths.ToArray()
            resultsDir  = $targetResultsDir
        }) | Out-Null
        continue
    }

    $aggregateRaw = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
    $aggregate = $null
    try {
        $aggregate = $aggregateRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $aggregate = $null
    }

    $stats = $null
    if ($aggregate -and $aggregate.PSObject.Properties['stats']) {
        $stats = $aggregate.stats
    }
    $processed = if ($stats -and $stats.PSObject.Properties['processed']) { [int]$stats.processed } else { 0 }
    $diffs = if ($stats -and $stats.PSObject.Properties['diffs']) { [int]$stats.diffs } else { 0 }
    $missing = if ($stats -and $stats.PSObject.Properties['missing']) { [int]$stats.missing } else { 0 }

    $totalComparisons += $processed
    $totalDiffs += $diffs
    $completedCount++
    if ($diffs -gt 0) { $diffTargetCount++ }

    $reportMarkdown = Join-Path $targetResultsDir 'history-report.md'
    if (-not (Test-Path -LiteralPath $reportMarkdown -PathType Leaf)) {
        $reportMarkdown = $null
    }
    $reportHtml = Join-Path $targetResultsDir 'history-report.html'
    if (-not (Test-Path -LiteralPath $reportHtml -PathType Leaf)) {
        $reportHtml = $null
    }

    [void]$summaryTargets.Add([pscustomobject]@{
        repoPath    = $repoPath
        status      = 'completed'
        changeTypes = $target.changeTypes.ToArray()
        basePaths   = $target.basePaths.ToArray()
        headPaths   = $target.headPaths.ToArray()
        resultsDir  = $targetResultsDir
        manifest    = $manifestPath
        reportMd    = $reportMarkdown
        reportHtml  = $reportHtml
        stats       = [pscustomobject]@{
            processed = $processed
            diffs     = $diffs
            missing   = $missing
        }
    }) | Out-Null
}

foreach ($skipped in $skippedPairs) {
    [void]$summaryTargets.Add([pscustomobject]@{
        repoPath    = if ($skipped.headPath) { $skipped.headPath } elseif ($skipped.basePath) { $skipped.basePath } else { '(unknown)' }
        status      = 'skipped'
        message     = 'Manifest entry missing base/head path on disk.'
        changeTypes = @($skipped.changeType)
        basePaths   = @($skipped.basePath)
        headPaths   = @($skipped.headPath)
    }) | Out-Null
}

$summary = [pscustomobject]@{
    schema      = 'pr-vi-history-summary@v1'
    generatedAt = (Get-Date).ToString('o')
    manifest    = $resolvedManifest
    resultsRoot = $resultsRootResolved
    maxPairs    = $MaxPairs
    modes       = if ($Mode) { @($Mode) } else { $null }
    totals      = [pscustomobject]@{
        targets          = $summaryTargets.Count
        completed        = $completedCount
        diffTargets      = $diffTargetCount
        comparisons      = $totalComparisons
        diffs            = $totalDiffs
        errors           = $errorTargets.Count
        skippedEntries   = $skippedPairs.Count
    }
    targets     = $summaryTargets
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $effectiveSummaryPath -Encoding utf8

if ($Env:GITHUB_OUTPUT) {
    "summary_path=$effectiveSummaryPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "results_root=$resultsRootResolved"  | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "target_count=$($summary.totals.targets)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "completed_count=$completedCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_target_count=$diffTargetCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "comparison_count=$totalComparisons" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_count=$totalDiffs" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "error_count=$($errorTargets.Count)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
}

if ($errorTargets.Count -gt 0) {
    $messages = $errorTargets | ForEach-Object { "{0}: {1}" -f $_.repoPath, $_.message }
    $message = "VI history execution failed for {0} target(s): {1}" -f $errorTargets.Count, ($messages -join '; ')
    throw $message
}

return $summary
