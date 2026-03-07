param(
    [string]$BaseVi,
    [string]$HeadVi,
    [string]$OutputDir,
    [string]$LabVIEWExePath,
    [string]$LabVIEWBitness = '64',
    [string]$LVComparePath,
    [string[]]$Flags,
    [switch]$ReplaceFlags,
    [switch]$AllowSameLeaf,
    [switch]$RenderReport,
    [ValidateSet('html', 'xml', 'text')]
    [string[]]$ReportFormat = 'html',
    [string]$JsonLogPath,
    [switch]$Quiet,
    [switch]$LeakCheck,
    [double]$LeakGraceSeconds = 0,
    [string]$LeakJsonPath,
    [string]$CaptureScriptPath,
    [switch]$Summary,
    [Nullable[int]]$TimeoutSeconds,
    [string]$NoiseProfile = 'full',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-StubRepoRoot {
    $override = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_REPO_ROOT', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        try {
            return [System.IO.Path]::GetFullPath($override)
        } catch {
            return $override
        }
    }

    $scriptRoot = Split-Path -Parent $PSCommandPath
    return [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..\..'))
}

function Resolve-StubAbsolutePath {
    param(
        [AllowNull()][AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

function Get-StubModeSlug {
    $candidates = @(
        [System.Environment]::GetEnvironmentVariable('COMPAREVI_HISTORY_MODE_SLUG', 'Process'),
        [System.Environment]::GetEnvironmentVariable('COMPAREVI_HISTORY_MODE', 'Process'),
        [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_MODE', 'Process')
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim().ToLowerInvariant()
        }
    }
    return 'default'
}

function Get-StubModeFixtureMap {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $map = @{}

    $jsonRaw = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_MODE_FIXTURE_MAP_JSON', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($jsonRaw)) {
        try {
            $parsed = $jsonRaw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($parsed) {
                foreach ($key in $parsed.Keys) {
                    $resolved = Resolve-StubAbsolutePath -PathValue ([string]$parsed[$key]) -RepoRoot $RepoRoot
                    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                        $map[[string]$key] = $resolved
                    }
                }
            }
        } catch {
            throw "Failed to parse STUB_COMPARE_MODE_FIXTURE_MAP_JSON: $($_.Exception.Message)"
        }
    }

    $pairRaw = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_MODE_FIXTURE_MAP', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($pairRaw)) {
        foreach ($entry in @($pairRaw -split ';')) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $parts = $entry -split '=', 2
            if ($parts.Count -ne 2) { continue }
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($value)) { continue }
            $resolved = Resolve-StubAbsolutePath -PathValue $value -RepoRoot $RepoRoot
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                $map[$key] = $resolved
            }
        }
    }

    return $map
}

function Resolve-StubFixtureRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ModeSlug
    )

    $explicitFixture = [System.Environment]::GetEnvironmentVariable('STUB_COMPARE_REPORT_FIXTURE', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($explicitFixture)) {
        return Resolve-StubAbsolutePath -PathValue $explicitFixture -RepoRoot $RepoRoot
    }

    $fixtureMap = Get-StubModeFixtureMap -RepoRoot $RepoRoot
    if ($fixtureMap.ContainsKey($ModeSlug)) {
        return [string]$fixtureMap[$ModeSlug]
    }

    return $null
}

function Get-DefaultStubReportHtml {
    param([Parameter(Mandatory = $true)][string]$ModeSlug)

    switch ($ModeSlug) {
        'attributes' {
            return @"
<!DOCTYPE html>
<html>
<body>
  <div class="included-attributes">
    <ul class="inclusion-list">
      <li class="checked">VI Attribute</li>
    </ul>
  </div>
  <details open>
    <summary class="difference-heading">1. VI Attribute - Documentation</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail">VI description changed for the comparison target.</li>
    </ol>
  </details>
</body>
</html>
"@
        }
        'front-panel' {
            return @"
<!DOCTYPE html>
<html>
<body>
  <details open>
    <summary class="difference-heading">1. Control Changes - Numeric Controls</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail">Front panel control label changed.</li>
    </ol>
  </details>
</body>
</html>
"@
        }
        'block-diagram' {
            return @"
<!DOCTYPE html>
<html>
<body>
  <details open>
    <summary class="difference-heading">1. Block Diagram - Structures</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail">Block diagram structure wiring changed.</li>
    </ol>
  </details>
  <details open>
    <summary class="difference-cosmetic-heading">2. Block Diagram Cosmetic - Frame Objects</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail-cosmetic">Block diagram cosmetic spacing changed.</li>
    </ol>
  </details>
</body>
</html>
"@
        }
        default {
            return @"
<!DOCTYPE html>
<html>
<body>
  <div class="included-attributes">
    <ul class="inclusion-list">
      <li class="checked">VI Attribute</li>
    </ul>
  </div>
  <details open>
    <summary class="difference-heading">1. VI Attribute - Window Size/Appearance</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail">Window bounds changed for the comparison target.</li>
    </ol>
  </details>
</body>
</html>
"@
        }
    }
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $env:TEMP ("lvcompare-stub-" + [guid]::NewGuid().ToString('N'))
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$imagesDir = Join-Path $OutputDir 'cli-images'
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null

$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$capturePath = Join-Path $OutputDir 'lvcompare-capture.json'

$repoRoot = Resolve-StubRepoRoot
$comparisonMode = Get-StubModeSlug
$fixtureRoot = Resolve-StubFixtureRoot -RepoRoot $repoRoot -ModeSlug $comparisonMode

"Stub LVCompare run for $BaseVi -> $HeadVi (mode=$comparisonMode)" | Set-Content -LiteralPath $stdoutPath -Encoding utf8
"" | Set-Content -LiteralPath $stderrPath -Encoding utf8
[System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA, 0xFE, 0xBA, 0xBE))

$exitCode = 1
$fixtureReportCopied = $false
$fixtureCaptureCopied = $false
$reportPath = Join-Path $OutputDir 'compare-report.html'

if (-not [string]::IsNullOrWhiteSpace($fixtureRoot) -and (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
    $reportSource = Join-Path $fixtureRoot 'compare-report.html'
    $captureSource = Join-Path $fixtureRoot 'lvcompare-capture.json'

    if (Test-Path -LiteralPath $reportSource -PathType Leaf) {
        Copy-Item -LiteralPath $reportSource -Destination $reportPath -Force
        $fixtureReportCopied = $true
    }

    if (Test-Path -LiteralPath $captureSource -PathType Leaf) {
        Copy-Item -LiteralPath $captureSource -Destination $capturePath -Force
        $fixtureCaptureCopied = $true
    }
}

if (($RenderReport.IsPresent -or $ReportFormat[-1].ToLowerInvariant() -eq 'html') -and -not $fixtureReportCopied) {
    $html = Get-DefaultStubReportHtml -ModeSlug $comparisonMode
    $html | Set-Content -LiteralPath $reportPath -Encoding utf8
}

if ($fixtureCaptureCopied -and (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    try {
        $captureData = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        $captureObject = [ordered]@{}
        foreach ($property in $captureData.PSObject.Properties) {
            $captureObject[$property.Name] = $property.Value
        }
        if (-not $captureObject.Contains('exitCode')) {
            if ($captureData.PSObject.Properties['cli'] -and $captureData.cli -and $captureData.cli.PSObject.Properties['exitCode']) {
                $captureObject.exitCode = [int]$captureData.cli.exitCode
            } else {
                $captureObject.exitCode = $exitCode
            }
        }
        if (-not $captureObject.Contains('seconds')) {
            if ($captureData.PSObject.Properties['cli'] -and $captureData.cli -and $captureData.cli.PSObject.Properties['duration_s']) {
                $captureObject.seconds = [double]$captureData.cli.duration_s
            } else {
                $captureObject.seconds = 0.05
            }
        }
        if (-not $captureObject.Contains('command')) {
            $captureObject.command = "Stub LVCompare ""$BaseVi"" ""$HeadVi"""
        }
        if (-not $captureObject.Contains('cliPath')) {
            $captureObject.cliPath = if ($LVComparePath) { $LVComparePath } else { 'Stub LVCompare' }
        }
        if (-not $captureObject.Contains('args')) {
            $captureObject.args = $Flags
        }
        if (-not $captureObject.Contains('base')) {
            $captureObject.base = $BaseVi
        }
        if (-not $captureObject.Contains('head')) {
            $captureObject.head = $HeadVi
        }
        $captureObject.comparisonMode = $comparisonMode
        if (-not $captureObject.Contains('environment') -or -not $captureObject.environment) {
            $captureObject.environment = @{}
        }
        if ($captureObject.environment -isnot [System.Collections.IDictionary]) {
            $environmentObject = [ordered]@{}
            foreach ($property in $captureObject.environment.PSObject.Properties) {
                $environmentObject[$property.Name] = $property.Value
            }
            $captureObject.environment = $environmentObject
        }
        $captureObject.environment.mode = @{
            slug = $comparisonMode
        }
        if (-not $captureObject.environment.Contains('cli') -or -not $captureObject.environment.cli) {
            $captureObject.environment.cli = @{}
        }
        if ($captureObject.environment.cli -isnot [System.Collections.IDictionary]) {
            $cliEnvironment = [ordered]@{}
            foreach ($property in $captureObject.environment.cli.PSObject.Properties) {
                $cliEnvironment[$property.Name] = $property.Value
            }
            $captureObject.environment.cli = $cliEnvironment
        }
        $captureObject.environment.cli.highlights = @()
        $captureObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8
    } catch {
        throw "Failed to normalize copied fixture capture '$capturePath': $($_.Exception.Message)"
    }
}

$reportHighlights = @()
$includedAttributes = @()
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    $reportHtml = Get-Content -LiteralPath $reportPath -Raw
    $summaryMatches = [regex]::Matches($reportHtml, '<summary[^>]*>(?<text>[^<]+)</summary>', 'IgnoreCase')
    foreach ($match in $summaryMatches) {
        $text = $match.Groups['text'].Value.Trim()
        if ($text) { $reportHighlights += $text }
    }
    $attrMatches = [regex]::Matches($reportHtml, '<li\s+class="checked">(?<text>[^<]+)</li>', 'IgnoreCase')
    foreach ($match in $attrMatches) {
        $name = [System.Net.WebUtility]::HtmlDecode($match.Groups['text'].Value.Trim())
        if ($name) {
            $includedAttributes += ,([pscustomobject]@{
                name = $name
                included = $true
            })
        }
    }
}
if ($includedAttributes.Count -gt 0) {
    foreach ($attr in $includedAttributes) {
        if ($attr -and $attr.name) { $reportHighlights += [string]$attr.name }
    }
}
$uniqueHighlights = @($reportHighlights | Where-Object { $_ } | Select-Object -Unique)

if ($fixtureCaptureCopied -and (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    try {
        $captureData = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        if ($captureData.PSObject.Properties['environment'] -and $captureData.environment) {
            if ($captureData.environment.PSObject.Properties['cli'] -and $captureData.environment.cli) {
                $captureData.environment.cli | Add-Member -NotePropertyName 'highlights' -NotePropertyValue $uniqueHighlights -Force
            }
        }
        $captureData | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8
    } catch {
        throw "Failed to refresh copied fixture capture highlights '$capturePath': $($_.Exception.Message)"
    }
}

if (-not $fixtureCaptureCopied) {
    $capture = [ordered]@{
        schema = 'lvcompare-capture-v1'
        timestamp = (Get-Date).ToString('o')
        base = $BaseVi
        head = $HeadVi
        cliPath = if ($LVComparePath) { $LVComparePath } else { 'Stub LVCompare' }
        args = $Flags
        exitCode = $exitCode
        seconds = 0.05
        command = "Stub LVCompare ""$BaseVi"" ""$HeadVi"""
        comparisonMode = $comparisonMode
        environment = @{
            mode = @{
                slug = $comparisonMode
            }
            cli = @{
                artifacts = @{
                    imageCount = 1
                    reportSizeBytes = if (Test-Path -LiteralPath $reportPath -PathType Leaf) { (Get-Item -LiteralPath $reportPath).Length } else { 0 }
                    images = @(
                        @{
                            index = 0
                            mimeType = 'image/png'
                            byteLength = 4
                            savedPath = (Join-Path $imagesDir 'cli-image-00.png')
                        }
                    )
                }
                highlights = $uniqueHighlights
            }
        }
    }
    $capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8
}

$metadata = [ordered]@{
    renderReport = $RenderReport.IsPresent
    reportFormat = if ($ReportFormat) { [string]$ReportFormat[-1] } else { 'html' }
    reportPath = $reportPath
    comparisonMode = $comparisonMode
    fixtureRoot = $fixtureRoot
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'report-flags.json') -Encoding utf8

$artifactLeaf = $null
$artifactParent = $null
if ($OutputDir) {
    try { $artifactLeaf = Split-Path -Leaf $OutputDir } catch { $artifactLeaf = $null }
    try { $artifactParent = Split-Path -Parent $OutputDir } catch { $artifactParent = $null }
}
if (-not $artifactLeaf) { $artifactLeaf = 'lvcompare-artifacts' }
$artifactBase = if ($artifactLeaf.EndsWith('-artifacts')) {
    $artifactLeaf.Substring(0, $artifactLeaf.Length - 10)
} else {
    $artifactLeaf
}
if (-not $artifactBase) { $artifactBase = 'lvcompare' }
$execPath = if ($artifactParent) {
    Join-Path $artifactParent ("$artifactBase-exec.json")
} else {
    Join-Path $OutputDir ("$artifactBase-exec.json")
}
$summaryPath = if ($artifactParent) {
    Join-Path $artifactParent ("$artifactBase-summary.json")
} else {
    Join-Path $OutputDir ("$artifactBase-summary.json")
}

$cliArgsRecorded = if ($Flags) { @($Flags | ForEach-Object { [string]$_ }) } else { $null }
$cliPathValue = if ($LVComparePath) { $LVComparePath } else { 'C:\Stub\LVCompare.exe' }
$cliCommandValue = ("Stub LVCompare ""{0}"" ""{1}""" -f $BaseVi, $HeadVi)

$execObject = [ordered]@{
    schema = 'compare-exec/v1'
    generatedAt = (Get-Date).ToString('o')
    cliPath = $cliPathValue
    command = $cliCommandValue
    args = $cliArgsRecorded
    exitCode = $exitCode
    diff = $true
    cwd = (Get-Location).Path
    duration_s = 0.05
    duration_ns = 50000000
    base = $BaseVi
    head = $HeadVi
    comparisonMode = $comparisonMode
}
$execObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $execPath -Encoding utf8

$cliSummary = [ordered]@{
    exitCode = $exitCode
    diff = $true
    duration_s = 0.05
    command = $cliCommandValue
    cliPath = $cliPathValue
    comparisonMode = $comparisonMode
    reportFormat = if ($ReportFormat) { [string]$ReportFormat[-1] } else { 'html' }
}
if ($cliArgsRecorded) { $cliSummary.args = $cliArgsRecorded }
if ($uniqueHighlights.Count -gt 0) { $cliSummary.highlights = $uniqueHighlights }
if ($includedAttributes.Count -gt 0) { $cliSummary.includedAttributes = $includedAttributes }
$cliSummary.stdoutPreview = @("Stub compare mode=$comparisonMode", "Base=$BaseVi", "Head=$HeadVi")

$outPaths = [ordered]@{
    execJson = $execPath
    captureJson = $capturePath
    reportPath = $reportPath
    stdout = $stdoutPath
    stderr = $stderrPath
}
$outPaths.reportHtml = $reportPath

$summaryObject = [ordered]@{
    schema = 'ref-compare-summary/v1'
    generatedAt = (Get-Date).ToString('o')
    name = Split-Path -Leaf $BaseVi
    path = $BaseVi
    refA = 'stub-refA'
    refB = 'stub-refB'
    temp = $OutputDir
    reportFormat = if ($ReportFormat) { [string]$ReportFormat[-1] } else { 'html' }
    comparisonMode = $comparisonMode
    out = [pscustomobject]$outPaths
    computed = [ordered]@{
        baseBytes = 123
        headBytes = 456
        baseSha = 'stub-base'
        headSha = 'stub-head'
        expectDiff = $true
    }
    cli = [pscustomobject]$cliSummary
}
$summaryObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8

if ($LeakCheck -and $LeakJsonPath) {
    $leakDir = Split-Path -Parent $LeakJsonPath
    if ($leakDir) {
        New-Item -ItemType Directory -Path $leakDir -Force | Out-Null
    }
    $leakInfo = [ordered]@{
        schema = 'lvcompare-leak-v1'
        generatedAt = (Get-Date).ToString('o')
        leakDetected = $false
        processes = @()
        graceSeconds = $LeakGraceSeconds
    }
    $leakInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LeakJsonPath -Encoding utf8
}

if ($JsonLogPath) {
    $logDir = Split-Path -Parent $JsonLogPath
    if ($logDir) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $crumb = [ordered]@{
        schema = 'lvcompare-log-v1'
        event = 'stub-run'
        timestamp = (Get-Date).ToString('o')
        diff = $true
        base = $BaseVi
        head = $HeadVi
        comparisonMode = $comparisonMode
    }
    $crumb | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}

if ($Summary) {
    Write-Host ("[Stub] LVCompare diff=True mode={0}" -f $comparisonMode)
}

exit $exitCode
