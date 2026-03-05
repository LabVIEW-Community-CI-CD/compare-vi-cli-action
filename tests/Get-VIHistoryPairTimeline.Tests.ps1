Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-VIHistoryPairTimeline' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repoRoot 'tools' 'Get-VIHistoryPairTimeline.ps1')
    }

    It 'extracts rows from pairTimeline and computes classification/timing stats' {
        $summary = [pscustomobject]@{
            pairTimeline = @(
                [pscustomobject]@{
                    targetPath = 'fixtures/vi-attr/Head.vi'
                    mode = 'default'
                    pairIndex = 1
                    baseRef = 'abc'
                    headRef = 'def'
                    diff = $true
                    classification = 'signal'
                    durationSeconds = 12.5
                },
                [pscustomobject]@{
                    targetPath = 'fixtures/vi-attr/Base.vi'
                    mode = 'default'
                    pairIndex = 2
                    baseRef = 'def'
                    headRef = 'ghi'
                    diff = $false
                    classification = 'noise-masscompile'
                    durationSeconds = 4.0
                }
            )
        }

        $result = Get-VIHistoryPairTimeline -Summary $summary
        $result.rows.Count | Should -Be 2
        $result.classificationCounts.signal | Should -Be 1
        $result.classificationCounts.'noise-masscompile' | Should -Be 1
        $result.timing.comparisonCount | Should -Be 2
        $result.timing.totalSeconds | Should -Be 16.5
        $result.timing.p50Seconds | Should -Be 4.0
        $result.timing.p95Seconds | Should -Be 12.5
    }

    It 'falls back to targets.commitPairs when pairTimeline is absent' {
        $summary = [pscustomobject]@{
            targets = @(
                [pscustomobject]@{
                    repoPath = 'fixtures/vi-attr/Head.vi'
                    commitPairs = @(
                        [pscustomobject]@{
                            pairIndex = 1
                            diff = $true
                            classification = 'signal'
                            durationSeconds = 7
                        }
                    )
                }
            )
        }

        $result = Get-VIHistoryPairTimeline -Summary $summary
        $result.rows.Count | Should -Be 1
        $result.rows[0].targetPath | Should -Be 'fixtures/vi-attr/Head.vi'
        $result.classificationCounts.signal | Should -Be 1
        $result.timing.totalSeconds | Should -Be 7.0
    }
}

