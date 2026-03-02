#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Invoke-PRVIHistory.ps1' {
    BeforeAll {
        $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-PRVIHistory.ps1')).ProviderPath
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
    }

    It 'invokes Compare-VIHistory once per unique VI and captures summary output' {
        $tempDir = Join-Path $TestDrive 'history-fixtures'
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $headPath = Join-Path $tempDir 'Head.vi'
        Set-Content -LiteralPath $headPath -Value 'vi-bytes'

        $manifestPath = Join-Path $TestDrive 'vi-diff-manifest.json'
        $manifest = [ordered]@{
            schema      = 'vi-diff-manifest@v1'
            generatedAt = (Get-Date).ToString('o')
            baseRef     = 'base'
            headRef     = 'head'
            pairs       = @(
                [ordered]@{
                    changeType = 'modified'
                    basePath   = 'Base.vi'
                    headPath   = $headPath
                },
                [ordered]@{
                    changeType = 'renamed'
                    basePath   = 'Legacy.vi'
                    headPath   = $headPath
                }
            )
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        $resultsRoot = Join-Path $TestDrive 'history-results'
        $invocations = [System.Collections.Generic.List[hashtable]]::new()
        $compareStub = {
            param([hashtable]$Arguments)
            $invocations.Add($Arguments) | Out-Null

            New-Item -ItemType Directory -Path $Arguments.ResultsDir -Force | Out-Null
            $summaryManifest = [ordered]@{
                schema      = 'vi-compare/history-suite@v1'
                targetPath  = $Arguments.TargetPath
                requestedStartRef = $Arguments.StartRef
                startRef    = $Arguments.StartRef
                stats       = [ordered]@{
                    processed = 3
                    diffs     = 1
                    missing   = 0
                }
                modes       = @(
                    [ordered]@{
                        name = 'default'
                        stats = [ordered]@{
                            processed = 3
                            diffs     = 1
                            missing   = 0
                        }
                        comparisons = @()
                    }
                )
            }
            $manifestOut = Join-Path $Arguments.ResultsDir 'manifest.json'
            $summaryManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Arguments.ResultsDir 'history-report.md') -Value '# history' -Encoding utf8
            $reportHtml = @'
<!DOCTYPE html>
<html><body>
  <img src="data:image/png;base64,AA==" alt="Preview">
</body></html>
'@
            Set-Content -LiteralPath (Join-Path $Arguments.ResultsDir 'history-report.html') -Value $reportHtml -Encoding utf8
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            $result = & $scriptPath `
                -ManifestPath $manifestPath `
                -ResultsRoot $resultsRoot `
                -CompareInvoker $compareStub `
                -MaxPairs 4
        }
        finally {
            Pop-Location
        }

        $invocations.Count | Should -Be 1
        $invocations[0].TargetPath | Should -Be $headPath
        $invocations[0].MaxPairs | Should -Be 4
        $invocations[0].FlagNoAttr | Should -BeFalse
        $invocations[0].FlagNoFp | Should -BeFalse
        $invocations[0].FlagNoFpPos | Should -BeFalse
        $invocations[0].FlagNoBdCosm | Should -BeFalse
        $invocations[0].ForceNoBd | Should -BeFalse
        $invocations[0].ContainsKey('ReplaceFlags') | Should -BeFalse
        $invocations[0].ContainsKey('AdditionalFlags') | Should -BeFalse
        $invocations[0].ContainsKey('LvCompareArgs') | Should -BeFalse

        $result | Should -Not -BeNullOrEmpty
        $result.schema | Should -Be 'pr-vi-history-summary@v1'
        $result.totals.completed | Should -Be 1
        $result.totals.diffTargets | Should -Be 1
        $result.targets.Count | Should -Be 1
        $result.kpi.commentTruncated | Should -BeFalse
        $result.kpi.truncationReason | Should -Be 'none'

        $target = $result.targets[0]
        $target.status | Should -Be 'completed'
        $target.stats.processed | Should -Be 3
        $target.stats.diffs | Should -Be 1
        $target.reportImages.status | Should -Be 'completed'
        $target.reportImages.exportedImageCount | Should -Be 1
        $target.reportImages.sourceImageCount | Should -Be 1
        Test-Path -LiteralPath $target.reportImages.indexPath -PathType Leaf | Should -BeTrue

        Test-Path -LiteralPath $result.resultsRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $result.targets[0].manifest -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $result.targets[0].reportMd -PathType Leaf | Should -BeTrue
    }

    It 'omits MaxPairs when no cap is provided and records null in the summary' {
        $tempDir = Join-Path $TestDrive 'history-fixtures-unbounded'
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $headPath = Join-Path $tempDir 'Head.vi'
        Set-Content -LiteralPath $headPath -Value 'vi-bytes'

        $manifestPath = Join-Path $TestDrive 'vi-diff-manifest-unbounded.json'
        $manifest = [ordered]@{
            schema      = 'vi-diff-manifest@v1'
            generatedAt = (Get-Date).ToString('o')
            baseRef     = 'base'
            headRef     = 'head'
            pairs       = @(
                [ordered]@{
                    changeType = 'modified'
                    basePath   = 'Base.vi'
                    headPath   = $headPath
                }
            )
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        $resultsRoot = Join-Path $TestDrive 'history-results-unbounded'
        $invocations = [System.Collections.Generic.List[hashtable]]::new()
        $compareStub = {
            param([hashtable]$Arguments)
            $invocations.Add($Arguments) | Out-Null

            New-Item -ItemType Directory -Path $Arguments.ResultsDir -Force | Out-Null
            $summaryManifest = [ordered]@{
                schema      = 'vi-compare/history-suite@v1'
                targetPath  = $Arguments.TargetPath
                requestedStartRef = $Arguments.StartRef
                startRef    = $Arguments.StartRef
                maxPairs    = $null
                stats       = [ordered]@{
                    processed = 2
                    diffs     = 0
                    missing   = 0
                }
                modes       = @(
                    [ordered]@{
                        name = 'default'
                        stats = [ordered]@{
                            processed = 2
                            diffs     = 0
                            missing   = 0
                            stopReason = 'complete'
                        }
                        comparisons = @()
                    }
                )
            }
            $manifestOut = Join-Path $Arguments.ResultsDir 'manifest.json'
            $summaryManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Arguments.ResultsDir 'history-report.md') -Value '# history' -Encoding utf8
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            $result = & $scriptPath `
                -ManifestPath $manifestPath `
                -ResultsRoot $resultsRoot `
                -CompareInvoker $compareStub `
                -SkipRenderReport
        }
        finally {
            Pop-Location
        }

        $invocations.Count | Should -Be 1
        $invocations[0].ContainsKey('MaxPairs') | Should -BeFalse

        $result.maxPairs | Should -BeNullOrEmpty
        $result.targets | Should -Not -BeNullOrEmpty
        $result.targets[0].status | Should -Be 'completed'
        $result.targets[0].stats.processed | Should -Be 2
        $result.targets[0].reportImages.status | Should -Be 'no-html-report'
        $result.targets[0].reportImages.exportedImageCount | Should -Be 0

        Test-Path -LiteralPath $result.targets[0].manifest -PathType Leaf | Should -BeTrue
    }

    It 'forwards compare timeout to Compare-VIHistory via explicit parameter and env fallback' {
        $tempDir = Join-Path $TestDrive 'history-fixtures-timeout'
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $headPath = Join-Path $tempDir 'Head.vi'
        Set-Content -LiteralPath $headPath -Value 'vi-bytes'

        $manifestPath = Join-Path $TestDrive 'vi-diff-manifest-timeout.json'
        $manifest = [ordered]@{
            schema      = 'vi-diff-manifest@v1'
            generatedAt = (Get-Date).ToString('o')
            baseRef     = 'base'
            headRef     = 'head'
            pairs       = @(
                [ordered]@{
                    changeType = 'modified'
                    basePath   = 'Base.vi'
                    headPath   = $headPath
                }
            )
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        $resultsRoot = Join-Path $TestDrive 'history-results-timeout'
        $invocations = [System.Collections.Generic.List[hashtable]]::new()
        $compareStub = {
            param([hashtable]$Arguments)
            $invocations.Add($Arguments) | Out-Null

            New-Item -ItemType Directory -Path $Arguments.ResultsDir -Force | Out-Null
            $summaryManifest = [ordered]@{
                schema      = 'vi-compare/history-suite@v1'
                targetPath  = $Arguments.TargetPath
                stats       = [ordered]@{
                    processed = 1
                    diffs     = 0
                    missing   = 0
                }
                modes       = @(
                    [ordered]@{
                        name = 'default'
                        stats = [ordered]@{
                            processed = 1
                            diffs     = 0
                            missing   = 0
                        }
                        comparisons = @()
                    }
                )
            }
            $manifestOut = Join-Path $Arguments.ResultsDir 'manifest.json'
            $summaryManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Arguments.ResultsDir 'history-report.md') -Value '# history' -Encoding utf8
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            & $scriptPath `
                -ManifestPath $manifestPath `
                -ResultsRoot $resultsRoot `
                -CompareInvoker $compareStub `
                -CompareTimeoutSeconds 777 `
                -SkipRenderReport | Out-Null

            $invocations.Count | Should -Be 1
            $invocations[0].CompareTimeoutSeconds | Should -Be 777

            $invocations.Clear()
            $env:PR_VI_HISTORY_COMPARE_TIMEOUT_SECONDS = '666'
            & $scriptPath `
                -ManifestPath $manifestPath `
                -ResultsRoot (Join-Path $TestDrive 'history-results-timeout-env') `
                -CompareInvoker $compareStub `
                -SkipRenderReport | Out-Null
        }
        finally {
            Remove-Item Env:PR_VI_HISTORY_COMPARE_TIMEOUT_SECONDS -ErrorAction SilentlyContinue
            Pop-Location
        }

        $invocations.Count | Should -Be 1
        $invocations[0].CompareTimeoutSeconds | Should -Be 666
    }

    It 'collects commit-pair timeline rows and timing aggregates from mode manifests' {
        $tempDir = Join-Path $TestDrive 'history-fixtures-timeline'
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $headPath = Join-Path $tempDir 'Head.vi'
        Set-Content -LiteralPath $headPath -Value 'vi-bytes'

        $manifestPath = Join-Path $TestDrive 'vi-diff-manifest-timeline.json'
        $manifest = [ordered]@{
            schema      = 'vi-diff-manifest@v1'
            generatedAt = (Get-Date).ToString('o')
            baseRef     = 'base'
            headRef     = 'head'
            pairs       = @(
                [ordered]@{
                    changeType = 'modified'
                    basePath   = 'Base.vi'
                    headPath   = $headPath
                }
            )
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        $resultsRoot = Join-Path $TestDrive 'history-results-timeline'
        $compareStub = {
            param([hashtable]$Arguments)

            New-Item -ItemType Directory -Path $Arguments.ResultsDir -Force | Out-Null
            $modeManifestPath = Join-Path $Arguments.ResultsDir 'default-manifest.json'
            $modeManifest = [ordered]@{
                schema = 'vi-compare/history@v1'
                mode   = 'default'
                stats  = [ordered]@{
                    processed = 2
                    diffs     = 1
                    missing   = 0
                }
                comparisons = @(
                    [ordered]@{
                        index = 1
                        base  = [ordered]@{ ref = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
                        head  = [ordered]@{ ref = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
                        result = [ordered]@{
                            diff          = $true
                            duration_s    = 1.25
                            classification= 'signal'
                            reportPath    = (Join-Path $Arguments.ResultsDir 'signal-report.html')
                        }
                    },
                    [ordered]@{
                        index = 2
                        base  = [ordered]@{ ref = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
                        head  = [ordered]@{ ref = 'cccccccccccccccccccccccccccccccccccccccc' }
                        result = [ordered]@{
                            diff          = $true
                            duration_s    = 2.75
                            classification= 'noise'
                            bucket        = 'metadata'
                            categories    = @('VI Attribute - Miscellaneous')
                            reportPath    = (Join-Path $Arguments.ResultsDir 'noise-report.html')
                        }
                    }
                )
            }
            $modeManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $modeManifestPath -Encoding utf8

            $summaryManifest = [ordered]@{
                schema      = 'vi-compare/history-suite@v1'
                targetPath  = $Arguments.TargetPath
                requestedStartRef = $Arguments.StartRef
                startRef    = $Arguments.StartRef
                stats       = [ordered]@{
                    processed = 2
                    diffs     = 1
                    missing   = 0
                }
                modes       = @(
                    [ordered]@{
                        name         = 'default'
                        slug         = 'default'
                        manifestPath = $modeManifestPath
                        stats        = [ordered]@{
                            processed = 2
                            diffs     = 1
                            missing   = 0
                        }
                    }
                )
            }
            $manifestOut = Join-Path $Arguments.ResultsDir 'manifest.json'
            $summaryManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestOut -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Arguments.ResultsDir 'history-report.md') -Value '# history' -Encoding utf8
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            $result = & $scriptPath `
                -ManifestPath $manifestPath `
                -ResultsRoot $resultsRoot `
                -CompareInvoker $compareStub `
                -SkipRenderReport
        }
        finally {
            Pop-Location
        }

        $result | Should -Not -BeNullOrEmpty
        $result.pairTimeline.Count | Should -Be 2
        $result.totals.pairRows | Should -Be 2
        $result.totals.diffPairRows | Should -Be 2
        $result.targets[0].commitPairs.Count | Should -Be 2
        $result.targets[0].commitPairs[0].classification | Should -Be 'signal'
        $result.targets[0].commitPairs[1].classification | Should -Be 'noise-masscompile'
        $result.targets[0].timing.totalSeconds | Should -Be 4
        $result.targets[0].timing.medianSeconds | Should -Be 2
        $result.totals.timing.totalSeconds | Should -Be 4
        $result.estimatedCompareTime.seconds | Should -Be 2
        $result.kpi.signalRecall | Should -Be 0.5
        $result.kpi.noisePrecisionMasscompile | Should -Be 1
        $result.kpi.previewCoverage | Should -Be 0
        $result.kpi.timingP50Seconds | Should -Be 1.25
        $result.kpi.timingP95Seconds | Should -Be 2.75
        $result.kpi.commentTruncated | Should -BeFalse
        $result.kpi.truncationReason | Should -Be 'none'
    }

    It 'prefers repo-relative target paths when the VI resides in the repository' {
        $manifestPath = Join-Path $TestDrive 'vi-diff-rel.json'
        $manifest = [ordered]@{
            schema = 'vi-diff-manifest@v1'
            pairs  = @(
                [ordered]@{
                    changeType = 'modified'
                    basePath   = 'fixtures/vi-attr/Base.vi'
                    headPath   = 'fixtures/vi-attr/Head.vi'
                }
            )
        }
        $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        $captured = [ref]$null
        $resultsRoot = Join-Path $TestDrive 'history-rel-results'
        $compareStub = {
            param([hashtable]$Arguments)
            $captured.Value = $Arguments.TargetPath

            New-Item -ItemType Directory -Path $Arguments.ResultsDir -Force | Out-Null
            $summaryManifest = [ordered]@{
                schema      = 'vi-compare/history-suite@v1'
                targetPath  = $Arguments.TargetPath
                requestedStartRef = $Arguments.StartRef
                startRef    = $Arguments.StartRef
                stats       = [ordered]@{
                    processed = 1
                    diffs     = 0
                    missing   = 0
                }
                modes       = @()
            }
            $manifestOut = Join-Path $Arguments.ResultsDir 'manifest.json'
            $summaryManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding utf8
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            $result = & $scriptPath `
                -ManifestPath $manifestPath `
                -ResultsRoot $resultsRoot `
                -CompareInvoker $compareStub `
                -SkipRenderReport
        }
        finally {
            Pop-Location
        }

        $captured.Value | Should -Be 'fixtures/vi-attr/Head.vi'
        $result | Should -Not -BeNullOrEmpty
        $result.targets.Count | Should -Be 1
        $result.targets[0].repoPath | Should -Be 'fixtures/vi-attr/Head.vi'

        $summaryPath = Join-Path $resultsRoot 'vi-history-summary.json'
        Test-Path -LiteralPath $summaryPath -PathType Leaf | Should -BeTrue
        $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
        $summaryJson.targets[0].repoPath | Should -Be 'fixtures/vi-attr/Head.vi'
    }

    It 'records skipped targets when both base and head paths are missing' {
        $manifestPath = Join-Path $TestDrive 'vi-diff-missing.json'
        $manifest = [ordered]@{
            schema = 'vi-diff-manifest@v1'
            pairs  = @(
                [ordered]@{
                    changeType = 'deleted'
                    basePath   = 'does-not-exist.vi'
                    headPath   = $null
                }
            )
        }
        $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        Push-Location $repoRoot
        try {
            $result = & $scriptPath -ManifestPath $manifestPath -ResultsRoot (Join-Path $TestDrive 'history-empty') -SkipRenderReport
        }
        finally {
            Pop-Location
        }

        $result.totals.targets | Should -Be 1
        $result.totals.completed | Should -Be 0
        $result.totals.diffTargets | Should -Be 0
        $result.targets[0].status | Should -Be 'skipped'
        $result.targets[0].message | Should -Match 'missing'
    }
}
