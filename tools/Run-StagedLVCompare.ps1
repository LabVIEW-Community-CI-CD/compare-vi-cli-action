#Requires -Version 7.0
<#
.SYNOPSIS
  Runs LVCompare against staged VI pairs recorded by Invoke-PRVIStaging.

.DESCRIPTION
  Loads a `vi-staging-results.json` payload, iterates staged entries, and
  invokes `tools/Invoke-LVCompare.ps1` for each pair using the existing staged
  Base/Head paths. The script records compare status/metadata alongside the
  original results, writes a `vi-staging-compare.json` summary, and exposes
  aggregate counts via `GITHUB_OUTPUT`. Non-zero LVCompare exit codes other than
  0/1 (same/diff) are treated as failures.

.PARAMETER ResultsPath
  Path to the staging results JSON emitted by Invoke-PRVIStaging.

.PARAMETER ArtifactsDir
  Directory where compare artifacts and updated summaries will be written.

.PARAMETER RenderReport
  When present, request an HTML compare report for each LVCompare invocation
  (default: enabled).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResultsPath,

    [Parameter(Mandatory)]
    [string]$ArtifactsDir,

    [switch]$RenderReport,

    [scriptblock]$InvokeLVCompare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf)) {
    throw "Staging results file not found: $ResultsPath"
}

$raw = Get-Content -LiteralPath $ResultsPath -Raw -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Verbose "Staging results at $ResultsPath are empty; skipping LVCompare."
    return
}

try {
    $results = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "Unable to parse staging results JSON at $ResultsPath: $($_.Exception.Message)"
}

if (-not $results) {
    Write-Verbose "No staged pairs present; skipping LVCompare."
    return
}

if ($results -isnot [System.Collections.IEnumerable]) {
    $results = @($results)
}

$repoRoot = (& git rev-parse --show-toplevel).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Unable to determine git repository root.'
}

$invokeScript = Join-Path $repoRoot 'tools' 'Invoke-LVCompare.ps1'
if (-not (Test-Path -LiteralPath $invokeScript -PathType Leaf)) {
    throw "Invoke-LVCompare.ps1 not found at $invokeScript"
}

if (-not $InvokeLVCompare) {
    $InvokeLVCompare = {
        param(
            [string]$BaseVi,
            [string]$HeadVi,
            [string]$OutputDir,
            [switch]$AllowSameLeaf,
            [switch]$RenderReport
        )

        $args = @(
            '-NoLogo', '-NoProfile',
            '-File', $using:invokeScript,
            '-BaseVi', $BaseVi,
            '-HeadVi', $HeadVi,
            '-OutputDir', $OutputDir,
            '-Summary'
        )
        if ($AllowSameLeaf.IsPresent) { $args += '-AllowSameLeaf' }
        if ($RenderReport.IsPresent) { $args += '-RenderReport' }

        & pwsh @args | Out-String | Out-Null
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
        }
    }.GetNewClosure()
}

New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
$compareRoot = Join-Path $ArtifactsDir 'compare'
New-Item -ItemType Directory -Path $compareRoot -Force | Out-Null

$comparisons = New-Object System.Collections.Generic.List[object]
$diffCount = 0
$matchCount = 0
$skipCount = 0
$errorCount = 0
$failureMessages = New-Object System.Collections.Generic.List[string]

$index = 1
foreach ($entry in $results) {
    $compareInfo = [ordered]@{
        status     = 'skipped'
        exitCode   = $null
        outputDir  = $null
        capturePath= $null
        reportPath = $null
    }

    $hasStaging =
        $entry -and
        $entry.PSObject.Properties['staged'] -and
        $entry.staged -and
        $entry.staged.PSObject.Properties['Base'] -and
        $entry.staged.PSObject.Properties['Head'] -and
        -not [string]::IsNullOrWhiteSpace($entry.staged.Base) -and
        -not [string]::IsNullOrWhiteSpace($entry.staged.Head)

    if ($hasStaging) {
        $pairDir = Join-Path $compareRoot ("pair-{0:D2}" -f $index)
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $invokeParams = @{
            BaseVi      = $entry.staged.Base
            HeadVi      = $entry.staged.Head
            OutputDir   = $pairDir
        }

        if ($RenderReport.IsPresent) { $invokeParams.RenderReport = $true }

        $allowSameLeafRequested = $false
        if ($entry.staged.PSObject.Properties['AllowSameLeaf']) {
            try {
                if ([bool]$entry.staged.AllowSameLeaf) {
                    $invokeParams.AllowSameLeaf = $true
                    $allowSameLeafRequested = $true
                }
            } catch {}
        }

        Write-Host ("[compare] Running LVCompare for pair {0}: Base={1} Head={2}" -f $index, $entry.basePath, $entry.headPath)
        $invokeResult = & $InvokeLVCompare @invokeParams

        $exitCode = $LASTEXITCODE
        if ($invokeResult -is [int]) {
            $exitCode = [int]$invokeResult
        } elseif ($invokeResult -and $invokeResult.PSObject.Properties['ExitCode']) {
            try { $exitCode = [int]$invokeResult.ExitCode } catch { $exitCode = $LASTEXITCODE }
        }

        $compareInfo.exitCode = $exitCode
        $compareInfo.outputDir = $pairDir

        $capturePath = Join-Path $pairDir 'lvcompare-capture.json'
        if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
            $compareInfo.capturePath = $capturePath
        }

        $reportCandidates = @('compare-report.html', 'compare-report.xml', 'compare-report.txt')
        foreach ($candidate in $reportCandidates) {
            $candidatePath = Join-Path $pairDir $candidate
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                $compareInfo.reportPath = $candidatePath
                break
            }
        }

        if ($invokeResult -and $invokeResult.PSObject.Properties['CapturePath'] -and $invokeResult.CapturePath) {
            $compareInfo.capturePath = $invokeResult.CapturePath
        }
        if ($invokeResult -and $invokeResult.PSObject.Properties['ReportPath'] -and $invokeResult.ReportPath) {
            $compareInfo.reportPath = $invokeResult.ReportPath
        }

        switch ($exitCode) {
            0 {
                $compareInfo.status = 'match'
                $matchCount++
            }
            1 {
                $compareInfo.status = 'diff'
                $diffCount++
            }
            default {
                $compareInfo.status = 'error'
                $errorCount++
                $failureMessages.Add("pair $index exit $exitCode")
            }
        }
    } else {
        $skipCount++
    }

    $entry | Add-Member -NotePropertyName compare -NotePropertyValue ([pscustomobject]$compareInfo) -Force

    $comparisons.Add([pscustomobject]@{
        index      = $index
        changeType = $entry.changeType
        basePath   = $entry.basePath
        headPath   = $entry.headPath
        status     = $compareInfo.status
        exitCode   = $compareInfo.exitCode
        outputDir  = $compareInfo.outputDir
        capturePath= $compareInfo.capturePath
        reportPath = $compareInfo.reportPath
    })

    $index++
}

$results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultsPath -Encoding utf8
$compareSummaryPath = Join-Path $ArtifactsDir 'vi-staging-compare.json'
$comparisons | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareSummaryPath -Encoding utf8

if ($Env:GITHUB_OUTPUT) {
    "results_path=$ResultsPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "compare_json=$compareSummaryPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "compare_dir=$compareRoot" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_count=$diffCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "match_count=$matchCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "skip_count=$skipCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "error_count=$errorCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
}

if ($failureMessages.Count -gt 0) {
    $message = "LVCompare reported failures for {0} staged pair(s): {1}" -f $failureMessages.Count, ($failureMessages -join '; ')
    throw $message
}
