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

    [string[]]$Flags,
    [switch]$ReplaceFlags,

    [scriptblock]$InvokeLVCompare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$flagsProvided = $PSBoundParameters.ContainsKey('Flags')
$effectiveFlags = $Flags
$effectiveReplace = $ReplaceFlags.IsPresent

function Get-RunStagedFlagList {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $lines = $Raw -split "(\r\n|\n|\r)"
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $candidate = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $result.Add($candidate)
    }
    return $result.ToArray()
}

function Get-EnvBoolean {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim().ToLowerInvariant()
    $truthy = @('1','true','yes','on')
    $falsy  = @('0','false','no','off')
    if ($truthy -contains $normalized) { return $true }
    if ($falsy -contains $normalized) { return $false }
    return $null
}

if (-not $flagsProvided) {
    $effectiveFlags = $null
    $envFlagCandidates = @(
        [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_FLAGS', 'Process'),
        [System.Environment]::GetEnvironmentVariable('VI_STAGE_COMPARE_FLAGS', 'Process')
    )
    foreach ($rawFlags in $envFlagCandidates) {
        if ([string]::IsNullOrWhiteSpace($rawFlags)) { continue }
        $parsedFlags = [string[]](Get-RunStagedFlagList -Raw $rawFlags)
        if ($parsedFlags -and $parsedFlags.Length -gt 0) {
            $effectiveFlags = $parsedFlags
            break
        } else {
            $effectiveFlags = $null
        }
    }
}

$modeCandidates = @()
$envModeRaw = [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_FLAGS_MODE', 'Process')
if (-not [string]::IsNullOrWhiteSpace($envModeRaw)) { $modeCandidates += $envModeRaw }
$stageModeRaw = [System.Environment]::GetEnvironmentVariable('VI_STAGE_COMPARE_FLAGS_MODE', 'Process')
if (-not [string]::IsNullOrWhiteSpace($stageModeRaw)) { $modeCandidates += $stageModeRaw }

if ($ReplaceFlags.IsPresent) {
    $effectiveReplace = $true
} else {
    $modeDecision = $null
    foreach ($mode in $modeCandidates) {
        if ([string]::IsNullOrWhiteSpace($mode)) { continue }
        $normalized = $mode.Trim().ToLowerInvariant()
        if ($normalized -eq 'replace' -or $normalized -eq 'append') {
            $modeDecision = $normalized
            break
        }
    }
    if ($modeDecision) {
        $effectiveReplace = ($modeDecision -eq 'replace')
    } else {
        $effectiveReplace = $true
    }
}

if (-not $effectiveReplace) {
    $envReplaceRaw = [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_REPLACE_FLAGS', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($envReplaceRaw)) {
        $value = $envReplaceRaw.Trim().ToLowerInvariant()
        $truthy = @('1','true','yes','on','replace')
        $falsy  = @('0','false','no','off','append')
        if ($truthy -contains $value) {
            $effectiveReplace = $true
        } elseif ($falsy -contains $value) {
            $effectiveReplace = $false
        }
    }
}

$profiles = New-Object System.Collections.Generic.List[pscustomobject]
if ($effectiveFlags -and $effectiveFlags.Count -gt 0) {
    $profiles.Add([pscustomobject]@{
        name    = 'filtered'
        flags   = @($effectiveFlags)
        replace = [bool]$effectiveReplace
    }) | Out-Null
}
# Always include an unsuppressed pass so cosmetic/front panel edits are detected.
$profiles.Add([pscustomobject]@{
    name    = 'full'
    flags   = @()
    replace = $true
}) | Out-Null

# Deduplicate profiles based on replace mode + flag list
$seenProfiles = New-Object System.Collections.Generic.HashSet[string]
$uniqueProfiles = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($profile in $profiles) {
    if (-not $profile) { continue }
    $flagKey = if ($profile.flags) { [string]::Join('|', $profile.flags) } else { '' }
    $key = ('{0}:{1}' -f ([bool]$profile.replace), $flagKey)
    if ($seenProfiles.Add($key)) {
        $uniqueProfiles.Add($profile) | Out-Null
    }
}
$profiles = $uniqueProfiles
if ($profiles.Count -eq 0) {
    $profiles.Add([pscustomobject]@{
        name    = 'full'
        flags   = @()
        replace = $true
    }) | Out-Null
}

$timeoutSeconds = $null
$timeoutRaw = [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS', 'Process')
if (-not [string]::IsNullOrWhiteSpace($timeoutRaw)) {
    $parsedTimeout = 0
    if ([int]::TryParse($timeoutRaw.Trim(), [ref]$parsedTimeout)) {
        if ($parsedTimeout -gt 0) {
            $timeoutSeconds = $parsedTimeout
        } else {
            Write-Warning ("RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS must be greater than zero. Value '{0}' ignored." -f $timeoutRaw)
        }
    } else {
        Write-Warning ("RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS is not a valid integer: '{0}'." -f $timeoutRaw)
    }
}

$leakCheckEnabled = $true
$leakCheckRaw = [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_LEAK_CHECK', 'Process')
$leakCheckValue = Get-EnvBoolean -Value $leakCheckRaw
if ($leakCheckValue -ne $null) { $leakCheckEnabled = $leakCheckValue }

$leakGraceSecondsOverride = $null
$leakGraceRaw = [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS', 'Process')
if (-not [string]::IsNullOrWhiteSpace($leakGraceRaw)) {
    $parsedGrace = 0.0
    if ([double]::TryParse($leakGraceRaw.Trim(), [ref]$parsedGrace)) {
        if ($parsedGrace -ge 0) {
            $leakGraceSecondsOverride = $parsedGrace
        } else {
            Write-Warning ("RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS must be non-negative. Value '{0}' ignored." -f $leakGraceRaw)
        }
    } else {
        Write-Warning ("RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS is not a valid number: '{0}'." -f $leakGraceRaw)
    }
}

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
    throw ("Unable to parse staging results JSON at {0}: {1}" -f $ResultsPath, $_.Exception.Message)
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
            [switch]$RenderReport,
            [string[]]$Flags,
            [switch]$ReplaceFlags
        )

        $args = @(
            '-NoLogo', '-NoProfile',
            '-File', $invokeScript,
            '-BaseVi', $BaseVi,
            '-HeadVi', $HeadVi,
            '-OutputDir', $OutputDir,
            '-Summary'
        )
        if ($AllowSameLeaf.IsPresent) { $args += '-AllowSameLeaf' }
        if ($RenderReport.IsPresent) { $args += '-RenderReport' }
        if ($ReplaceFlags.IsPresent) { $args += '-ReplaceFlags' }
        if ($Flags) { $args += @('-Flags') + $Flags }

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
$leakWarningCount = 0
$failureMessages = New-Object System.Collections.Generic.List[string]

$index = 1
foreach ($entry in $results) {
    $compareInfo = [ordered]@{
        status     = 'skipped'
        exitCode   = $null
        outputDir  = $null
        capturePath= $null
        reportPath = $null
        allowSameLeaf = $false
    }

    $hasStaging =
        $entry -and
        $entry.PSObject.Properties['staged'] -and
        $entry.staged -and
        $entry.staged.PSObject.Properties['Base'] -and
        $entry.staged.PSObject.Properties['Head'] -and
        -not [string]::IsNullOrWhiteSpace($entry.staged.Base) -and
        -not [string]::IsNullOrWhiteSpace($entry.staged.Head)

    $stagedBasePath = $null
    $stagedHeadPath = $null
    $pairDir = $null

    $allowSameLeafRequested = $false
    if ($hasStaging) {
        $pairDir = Join-Path $compareRoot ("pair-{0:D2}" -f $index)
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $stagedBasePath = $entry.staged.Base
        $stagedHeadPath = $entry.staged.Head

        if ([string]::IsNullOrWhiteSpace($stagedBasePath) -or [string]::IsNullOrWhiteSpace($stagedHeadPath)) {
            throw "Staged paths missing for pair $index. Base='$stagedBasePath' Head='$stagedHeadPath'."
        }

        if ([string]::Equals($stagedBasePath, $stagedHeadPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Staged pair $index produced identical Base/Head paths (`$stagedBasePath`)."
        }

        $stagedBaseLeaf = try { Split-Path -Leaf $stagedBasePath } catch { $null }
        $stagedHeadLeaf = try { Split-Path -Leaf $stagedHeadPath } catch { $null }
        if ($stagedBaseLeaf -and $stagedHeadLeaf -and
            [string]::Equals($stagedBaseLeaf, $stagedHeadLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Staged pair $index produced identical Base/Head filenames (`$stagedBaseLeaf`)."
        }

        if ($entry.staged.PSObject.Properties['AllowSameLeaf']) {
            try {
                if ([bool]$entry.staged.AllowSameLeaf) {
                    $allowSameLeafRequested = $true
                }
            } catch {}
        }
        if ($allowSameLeafRequested) {
            $compareInfo.allowSameLeaf = $true
        }

        $profileResults = New-Object System.Collections.Generic.List[pscustomobject]
        $pairErrorMessages = New-Object System.Collections.Generic.List[string]
        $pairLeakWarning = $false
        $pairLeakRecord = $null
        $primaryProfile = $null
        $modeIndex = 0

        foreach ($profile in $profiles) {
            if (-not $profile) { continue }
            $modeIndex++
            $modeName = [string]$profile.name
            if ([string]::IsNullOrWhiteSpace($modeName)) { $modeName = "mode-$modeIndex" }
            $safeName = ($modeName -replace '[^A-Za-z0-9\-]+','-').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "mode-$modeIndex" }

            if ($profileResults.Count -eq 0) {
                $modeOutputDir = $pairDir
            } else {
                $modeOutputDir = Join-Path $pairDir ("mode-{0}" -f $safeName)
                New-Item -ItemType Directory -Path $modeOutputDir -Force | Out-Null
            }

            $invokeParams = @{
                BaseVi    = $stagedBasePath
                HeadVi    = $stagedHeadPath
                OutputDir = $modeOutputDir
            }
            if ($RenderReport.IsPresent) { $invokeParams.RenderReport = $true }
            if ($profile.flags -and $profile.flags.Count -gt 0) { $invokeParams.Flags = $profile.flags }
            if ($profile.replace) { $invokeParams.ReplaceFlags = $true }
            if ($timeoutSeconds) { $invokeParams.TimeoutSeconds = $timeoutSeconds }
            if ($leakCheckEnabled) {
                $invokeParams.LeakCheck = $true
                if ($leakGraceSecondsOverride -ne $null) { $invokeParams.LeakGraceSeconds = [double]$leakGraceSecondsOverride }
            }
            if ($allowSameLeafRequested) { $invokeParams.AllowSameLeaf = $true }

            Write-Host ("[compare] Running LVCompare (mode={0}) for pair {1}: Base={2} -> {3} Head={4} -> {5}" -f `
                $modeName, $index, $entry.basePath, $stagedBasePath, $entry.headPath, $stagedHeadPath)
            $invokeResult = & $InvokeLVCompare @invokeParams

            $exitCode = $LASTEXITCODE
            if ($invokeResult -is [int]) {
                $exitCode = [int]$invokeResult
            } elseif ($invokeResult -and $invokeResult.PSObject.Properties['ExitCode']) {
                try { $exitCode = [int]$invokeResult.ExitCode } catch {}
            }

            $modeInfo = [ordered]@{
                name      = $modeName
                flags     = @()
                replace   = [bool]$profile.replace
                exitCode  = $exitCode
                outputDir = $modeOutputDir
            }
            if ($profile.flags) { $modeInfo.flags = @($profile.flags) }
            if ($allowSameLeafRequested) { $modeInfo.allowSameLeaf = $true }

            $reportCandidates = @('compare-report.html', 'compare-report.xml', 'compare-report.txt')
            foreach ($candidate in $reportCandidates) {
                $candidatePath = Join-Path $modeOutputDir $candidate
                if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                    $modeInfo.reportPath = $candidatePath
                    break
                }
            }

            if ($invokeResult -and $invokeResult.PSObject.Properties['CapturePath'] -and $invokeResult.CapturePath) {
                $modeInfo.capturePath = $invokeResult.CapturePath
            } else {
                $candidateCapture = Join-Path $modeOutputDir 'lvcompare-capture.json'
                if (Test-Path -LiteralPath $candidateCapture -PathType Leaf) {
                    $modeInfo.capturePath = $candidateCapture
                }
            }
            if ($invokeResult -and $invokeResult.PSObject.Properties['ReportPath'] -and $invokeResult.ReportPath) {
                $modeInfo.reportPath = $invokeResult.ReportPath
            }

            $modeStatus = 'match'
            switch ($exitCode) {
                0 { $modeStatus = 'match' }
                1 { $modeStatus = 'diff' }
                default { $modeStatus = 'error' }
            }
            $modeInfo.status = $modeStatus

            if ($leakCheckEnabled) {
                $leakPath = Join-Path $modeOutputDir 'compare-leak.json'
                if (Test-Path -LiteralPath $leakPath -PathType Leaf) {
                    $modeLeak = $null
                    try {
                        $modeLeak = Get-Content -LiteralPath $leakPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 4
                    } catch {
                        Write-Warning ("[compare] Failed to parse leak summary for pair {0} (mode={1}): {2}" -f $index, $modeName, $_.Exception.Message)
                    }
                    if ($modeLeak) {
                        $lvLeak = 0
                        $labLeak = 0
                        if ($modeLeak.PSObject.Properties['lvcompare'] -and $modeLeak.lvcompare.PSObject.Properties['count']) {
                            try { $lvLeak = [int]$modeLeak.lvcompare.count } catch { $lvLeak = 0 }
                        }
                        if ($modeLeak.PSObject.Properties['labview'] -and $modeLeak.labview.PSObject.Properties['count']) {
                            try { $labLeak = [int]$modeLeak.labview.count } catch { $labLeak = 0 }
                        }
                        $modeInfo.leak = [pscustomobject]@{
                            path      = $leakPath
                            lvcompare = $lvLeak
                            labview   = $labLeak
                        }
                        if ($lvLeak -gt 0 -or $labLeak -gt 0) {
                            $modeInfo.leakWarning = $true
                            $pairLeakWarning = $true
                            if (-not $pairLeakRecord) {
                                $pairLeakRecord = $modeInfo.leak
                            }
                        }
                    }
                }
            }

            $profileResults.Add([pscustomobject]$modeInfo) | Out-Null
            $currentProfile = $profileResults[$profileResults.Count - 1]
            if (-not $primaryProfile) {
                $primaryProfile = $currentProfile
            } elseif ($currentProfile.status -eq 'diff' -and $primaryProfile.status -ne 'diff') {
                $primaryProfile = $currentProfile
            }

            if ($modeStatus -eq 'error') {
                $pairErrorMessages.Add("mode $modeName exit $exitCode") | Out-Null
            }
        }

        if ($profileResults.Count -eq 0) {
            $compareInfo.status = 'skipped'
            $skipCount++
        } else {
            $overallStatus = 'match'
            $hasDiff = $false
            $hasError = $false
            foreach ($mode in $profileResults) {
                if ($mode.status -eq 'diff') { $hasDiff = $true }
                elseif ($mode.status -eq 'error') { $hasError = $true }
            }
            if ($hasDiff) {
                $overallStatus = 'diff'
                $diffCount++
            } elseif ($hasError) {
                $overallStatus = 'error'
                $errorCount++
            } else {
                $matchCount++
            }
            if ($hasError -and $pairErrorMessages.Count -gt 0) {
                $failureMessages.Add("pair ${index}: {0}" -f ($pairErrorMessages -join '; '))
            }
            $compareInfo.status = $overallStatus

            if (-not $primaryProfile) {
                $primaryProfile = $profileResults[0]
            }
            $compareInfo.primaryMode = $primaryProfile.name
            $compareInfo.exitCode = $primaryProfile.exitCode
            $compareInfo.outputDir = $primaryProfile.outputDir
            if ($primaryProfile.PSObject.Properties['capturePath'] -and $primaryProfile.capturePath) {
                $compareInfo.capturePath = $primaryProfile.capturePath
            }
            if ($primaryProfile.PSObject.Properties['reportPath'] -and $primaryProfile.reportPath) {
                $compareInfo.reportPath = $primaryProfile.reportPath
            }
            if ($primaryProfile.PSObject.Properties['flags'] -and $primaryProfile.flags) {
                $compareInfo.flags = @($primaryProfile.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            } else {
                $compareInfo.flags = @()
            }
        }

        $compareInfo.modes = @($profileResults.ToArray())
        if ($pairLeakWarning) {
            $compareInfo.leakWarning = $true
            $leakWarningCount++
        }
        if ($pairLeakRecord) {
            $compareInfo.leak = $pairLeakRecord
            if ($pairLeakRecord.PSObject.Properties['lvcompare']) { $compareInfo.leakLvcompare = $pairLeakRecord.lvcompare }
            if ($pairLeakRecord.PSObject.Properties['labview']) { $compareInfo.leakLabVIEW = $pairLeakRecord.labview }
            if ($pairLeakRecord.PSObject.Properties['path']) { $compareInfo.leakPath = $pairLeakRecord.path }
        }
    } else {
        $skipCount++
        $compareInfo.status = 'skipped'
        $compareInfo.modes = @()
    }

    $entry | Add-Member -NotePropertyName compare -NotePropertyValue ([pscustomobject]$compareInfo) -Force

    $compareLeakWarning = $false
    $leakRecord = $null
    if ($compareInfo -is [System.Collections.IDictionary]) {
        if ($compareInfo.Contains('leakWarning')) { $compareLeakWarning = [bool]$compareInfo['leakWarning'] }
        if ($compareInfo.Contains('leak')) { $leakRecord = $compareInfo['leak'] }
    } elseif ($compareInfo.PSObject) {
        if ($compareInfo.PSObject.Properties['leakWarning']) {
            try { $compareLeakWarning = [bool]$compareInfo.leakWarning } catch { $compareLeakWarning = $compareInfo.leakWarning }
        }
        if ($compareInfo.PSObject.Properties['leak']) { $leakRecord = $compareInfo.leak }
    }

    $leakLvValue = $null
    $leakLabValue = $null
    $leakPathValue = $null
    if ($leakRecord) {
        if ($leakRecord -is [System.Collections.IDictionary]) {
            if ($leakRecord.Contains('lvcompare')) { $leakLvValue = $leakRecord['lvcompare'] }
            if ($leakRecord.Contains('labview')) { $leakLabValue = $leakRecord['labview'] }
            if ($leakRecord.Contains('path')) { $leakPathValue = $leakRecord['path'] }
        } elseif ($leakRecord.PSObject) {
            if ($leakRecord.PSObject.Properties['lvcompare']) { $leakLvValue = $leakRecord.lvcompare }
            if ($leakRecord.PSObject.Properties['labview']) { $leakLabValue = $leakRecord.labview }
            if ($leakRecord.PSObject.Properties['path']) { $leakPathValue = $leakRecord.path }
        }
    }

    $leakLvInt = $null
    if ($leakLvValue -ne $null) {
        try { $leakLvInt = [int]$leakLvValue } catch { $leakLvInt = $leakLvValue }
    }
    $leakLabInt = $null
    if ($leakLabValue -ne $null) {
        try { $leakLabInt = [int]$leakLabValue } catch { $leakLabInt = $leakLabValue }
    }

    $comparisons.Add([pscustomobject]@{
        index         = $index
        changeType    = $entry.changeType
        basePath      = $entry.basePath
        headPath      = $entry.headPath
        stagedBase    = $stagedBasePath
        stagedHead    = $stagedHeadPath
        status        = $compareInfo.status
        exitCode      = $compareInfo.exitCode
        outputDir     = $compareInfo.outputDir
        capturePath   = $compareInfo.capturePath
        reportPath    = $compareInfo.reportPath
        allowSameLeaf = $allowSameLeafRequested
        leakWarning   = [bool]$compareLeakWarning
        leakLvcompare = $leakLvInt
        leakLabVIEW   = $leakLabInt
        leakPath      = $leakPathValue
        primaryMode   = $compareInfo.primaryMode
        modes         = $compareInfo.modes
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
    "leak_warning_count=$leakWarningCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
}

if ($failureMessages.Count -gt 0) {
    $message = "LVCompare reported failures for {0} staged pair(s): {1}" -f $failureMessages.Count, ($failureMessages -join '; ')
    throw $message
}

$global:LASTEXITCODE = 0
