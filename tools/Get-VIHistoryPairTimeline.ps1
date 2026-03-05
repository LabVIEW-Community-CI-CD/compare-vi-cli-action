Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VIHistoryPairTimeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Summary
    )

    $rows = New-Object System.Collections.Generic.List[pscustomobject]
    $classificationCounts = @{}
    $durations = New-Object System.Collections.Generic.List[double]

    $addPair = {
        param(
            [AllowNull()]
            [object]$Pair,
            [string]$FallbackTargetPath
        )
        if (-not $Pair) { return }

        $targetPath = if ($Pair.PSObject.Properties['targetPath'] -and $Pair.targetPath) {
            [string]$Pair.targetPath
        } else {
            $FallbackTargetPath
        }
        $classification = if ($Pair.PSObject.Properties['classification'] -and $Pair.classification) {
            [string]$Pair.classification
        } else {
            'unknown'
        }
        $durationSeconds = $null
        if ($Pair.PSObject.Properties['durationSeconds']) {
            try {
                $durationSeconds = [double]$Pair.durationSeconds
            } catch {
                $durationSeconds = $null
            }
        }

        $key = $classification.ToLowerInvariant()
        if (-not $classificationCounts.ContainsKey($key)) {
            $classificationCounts[$key] = 0
        }
        $classificationCounts[$key] = [int]$classificationCounts[$key] + 1

        if ($durationSeconds -ne $null -and $durationSeconds -ge 0) {
            $durations.Add($durationSeconds) | Out-Null
        }

        $rows.Add([pscustomobject]@{
            targetPath      = $targetPath
            mode            = if ($Pair.PSObject.Properties['mode']) { [string]$Pair.mode } else { 'default' }
            pairIndex       = if ($Pair.PSObject.Properties['pairIndex']) { [int]$Pair.pairIndex } else { $null }
            baseRef         = if ($Pair.PSObject.Properties['baseRef']) { [string]$Pair.baseRef } else { $null }
            headRef         = if ($Pair.PSObject.Properties['headRef']) { [string]$Pair.headRef } else { $null }
            diff            = if ($Pair.PSObject.Properties['diff']) { [bool]$Pair.diff } else { $false }
            classification  = $classification
            durationSeconds = $durationSeconds
        }) | Out-Null
    }

    if ($Summary -and $Summary.PSObject.Properties['pairTimeline'] -and $Summary.pairTimeline -is [System.Collections.IEnumerable]) {
        foreach ($pair in @($Summary.pairTimeline)) {
            & $addPair -Pair $pair -FallbackTargetPath $null
        }
    } elseif ($Summary -and $Summary.PSObject.Properties['targets'] -and $Summary.targets -is [System.Collections.IEnumerable]) {
        foreach ($target in @($Summary.targets)) {
            if (-not $target) { continue }
            $fallbackTargetPath = if ($target.PSObject.Properties['repoPath']) { [string]$target.repoPath } else { $null }
            if (-not ($target.PSObject.Properties['commitPairs'] -and $target.commitPairs -is [System.Collections.IEnumerable])) {
                continue
            }
            foreach ($pair in @($target.commitPairs)) {
                & $addPair -Pair $pair -FallbackTargetPath $fallbackTargetPath
            }
        }
    }

    $sortedDurations = @($durations | Sort-Object)
    $durationCount = $sortedDurations.Count
    $totalSeconds = 0.0
    foreach ($duration in $sortedDurations) {
        $totalSeconds += [double]$duration
    }

    $p50 = $null
    $p95 = $null
    if ($durationCount -gt 0) {
        $midIndex = [Math]::Floor(($durationCount - 1) / 2)
        $p50 = [double]$sortedDurations[$midIndex]
        $p95Index = [Math]::Ceiling(($durationCount * 0.95) - 1)
        $p95Index = [Math]::Max(0, [Math]::Min($durationCount - 1, [int]$p95Index))
        $p95 = [double]$sortedDurations[$p95Index]
    }

    [pscustomobject]@{
        rows = @($rows)
        classificationCounts = [pscustomobject]$classificationCounts
        timing = [pscustomobject]@{
            comparisonCount = $durationCount
            totalSeconds = [Math]::Round($totalSeconds, 6)
            p50Seconds = if ($p50 -ne $null) { [Math]::Round([double]$p50, 6) } else { $null }
            p95Seconds = if ($p95 -ne $null) { [Math]::Round([double]$p95, 6) } else { $null }
        }
    }
}

