#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Write-VIHistoryBenchmark.ps1' {
    BeforeAll {
        $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Write-VIHistoryBenchmark.ps1')).ProviderPath
    }

    It 'writes benchmark artifacts and reports insufficient baseline when no prior run exists' {
        $summaryPath = Join-Path $TestDrive 'vi-history-smoke-current.json'
        $benchmarksDir = Join-Path $TestDrive 'benchmarks'
        New-Item -ItemType Directory -Path $benchmarksDir -Force | Out-Null

        [ordered]@{
            Scenario = 'attribute'
            RunId = 1001
            PrNumber = 55
            Success = $true
            Comparisons = 3
            Diffs = 2
            PairClassification = [ordered]@{
                signal = 1
                'noise-masscompile' = 1
                unknown = 1
            }
            PairTiming = [ordered]@{
                comparisonCount = 3
                totalSeconds = 9.0
                p50Seconds = 2.0
                p95Seconds = 5.0
            }
            PairTimeline = @(
                [ordered]@{ previewStatus = 'present' },
                [ordered]@{ previewStatus = 'missing' },
                [ordered]@{ previewStatus = 'present' }
            )
            CommentTruncated = $false
            TruncationReason = 'none'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8

        $result = & $scriptPath -SmokeSummaryPath $summaryPath -BenchmarksDir $benchmarksDir -BaselineWindow 5

        $result.baselineCount | Should -Be 0
        $result.deltaStatus | Should -Be 'insufficient-baseline'
        Test-Path -LiteralPath $result.benchmarkPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $result.deltaPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $result.commentPath -PathType Leaf | Should -BeTrue

        $benchmark = Get-Content -LiteralPath $result.benchmarkPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        $benchmark.schema | Should -Be 'vi-history-benchmark@v1'
        $benchmark.metrics.pairCounts.total | Should -Be 3
        $benchmark.metrics.pairCounts.signal | Should -Be 1
        $benchmark.metrics.previewCoverage | Should -Be 0.666667

        $delta = Get-Content -LiteralPath $result.deltaPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        $delta.schema | Should -Be 'vi-history-benchmark-delta@v1'
        $delta.status | Should -Be 'insufficient-baseline'

        $comment = Get-Content -LiteralPath $result.commentPath -Raw -Encoding utf8
        $comment | Should -Match 'Baseline unavailable'
    }

    It 'computes KPI deltas against prior successful benchmarks for the same scenario' {
        $summaryPath = Join-Path $TestDrive 'vi-history-smoke-current-ready.json'
        $benchmarksDir = Join-Path $TestDrive 'benchmarks-ready'
        New-Item -ItemType Directory -Path $benchmarksDir -Force | Out-Null

        $baselinePath = Join-Path $benchmarksDir 'vi-history-benchmark-20260101010101.json'
        [ordered]@{
            schema = 'vi-history-benchmark@v1'
            generatedAt = (Get-Date).ToString('o')
            scenario = 'attribute'
            success = $true
            metrics = [ordered]@{
                pairCounts = [ordered]@{
                    total = 2
                    signal = 1
                    noiseMasscompile = 1
                    noiseCosmetic = 0
                    unknown = 0
                    comparisons = 2
                    diffs = 2
                }
                timing = [ordered]@{
                    totalSeconds = 6
                    p50Seconds = 2
                    p95Seconds = 4
                }
                previewCoverage = 0.5
                truncation = [ordered]@{
                    commentTruncated = $false
                    reason = 'none'
                }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $baselinePath -Encoding utf8

        [ordered]@{
            Scenario = 'attribute'
            RunId = 1002
            PrNumber = 56
            Success = $true
            Comparisons = 3
            Diffs = 2
            PairClassification = [ordered]@{
                signal = 2
                'noise-masscompile' = 1
            }
            PairTiming = [ordered]@{
                comparisonCount = 3
                totalSeconds = 9
                p50Seconds = 3
                p95Seconds = 5
            }
            PairTimeline = @(
                [ordered]@{ previewStatus = 'present' },
                [ordered]@{ previewStatus = 'present' },
                [ordered]@{ previewStatus = 'missing' }
            )
            CommentTruncated = $true
            TruncationReason = 'max-markdown-length'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8

        $result = & $scriptPath -SmokeSummaryPath $summaryPath -BenchmarksDir $benchmarksDir -BaselineWindow 5

        $result.baselineCount | Should -Be 1
        $result.deltaStatus | Should -Be 'ready'

        $delta = Get-Content -LiteralPath $result.deltaPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        $delta.status | Should -Be 'ready'
        $delta.delta.pairTotal | Should -Be 1
        $delta.delta.signalPairs | Should -Be 1
        $delta.delta.previewCoverage | Should -Be 0.166667

        $comment = Get-Content -LiteralPath $result.commentPath -Raw -Encoding utf8
        $comment | Should -Match '\| Metric \| Current \| Baseline \| Delta \|'
        $comment | Should -Match 'Timing P95'
    }
}
