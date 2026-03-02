#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Summarize-PRVIHistory.ps1' {
    BeforeAll {
        $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Summarize-PRVIHistory.ps1')).ProviderPath
    }

    It 'renders markdown with diff totals and report links' {
        $resultsRoot = Join-Path $TestDrive 'pr-history'
        $targetDir = Join-Path $resultsRoot '01-Example'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

        $reportMd = Join-Path $targetDir 'history-report.md'
        $reportHtml = Join-Path $targetDir 'history-report.html'
        Set-Content -LiteralPath $reportMd -Value '# Sample' -Encoding utf8
        Set-Content -LiteralPath $reportHtml -Value '<html></html>' -Encoding utf8
        $previewDir = Join-Path $targetDir 'previews'
        New-Item -ItemType Directory -Path $previewDir -Force | Out-Null
        $previewImage = Join-Path $previewDir 'history-image-000.png'
        [System.IO.File]::WriteAllBytes($previewImage, @(0xAA, 0xBB, 0xCC))
        $imageIndex = Join-Path $targetDir 'vi-history-image-index.json'
        [ordered]@{
            schema             = 'pr-vi-history-image-index@v1'
            generatedAt        = (Get-Date).ToString('o')
            reportPath         = $reportHtml
            outputDir          = $previewDir
            sourceImageCount   = 1
            exportedImageCount = 1
            images             = @(
                [ordered]@{
                    index      = 0
                    source     = 'data:image/png;base64,AA=='
                    sourceType = 'embedded'
                    alt        = 'Preview'
                    status     = 'saved'
                    fileName   = 'history-image-000.png'
                    savedPath  = $previewImage
                    byteLength = 3
                }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $imageIndex -Encoding utf8

        $summaryPath = Join-Path $TestDrive 'pr-history-summary.json'
        $summaryPayload = [ordered]@{
            schema      = 'pr-vi-history-summary@v1'
            generatedAt = (Get-Date).ToString('o')
            resultsRoot = $resultsRoot
            timing      = [ordered]@{
                comparisonCount = 2
                totalSeconds    = 3.75
            }
            pairTimeline = @(
                [ordered]@{
                    targetPath     = 'fixtures/Example.vi'
                    mode           = 'default'
                    pairIndex      = 1
                    baseRef        = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                    headRef        = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                    diff           = $true
                    classification = 'signal'
                    durationSeconds= 1.5
                    previewStatus  = 'present'
                    reportPath     = $reportHtml
                    imageIndexPath = $imageIndex
                },
                [ordered]@{
                    targetPath     = 'fixtures/Example.vi'
                    mode           = 'default'
                    pairIndex      = 2
                    baseRef        = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                    headRef        = 'cccccccccccccccccccccccccccccccccccccccc'
                    diff           = $false
                    classification = 'unknown'
                    durationSeconds= 2.25
                    previewStatus  = 'missing'
                    reportPath     = $null
                    imageIndexPath = $imageIndex
                }
            )
            targets     = @(
                [ordered]@{
                    repoPath    = 'fixtures/Example.vi'
                    status      = 'completed'
                    changeTypes = @('modified','renamed')
                    stats       = [ordered]@{
                        processed          = 4
                        diffs              = 2
                        durationSeconds    = 12.5
                        durationSamples    = 4
                        durationAvgSeconds = 3.125
                    }
                    reportMd   = $reportMd
                    reportHtml = $reportHtml
                    reportImages = [ordered]@{
                        status             = 'completed'
                        indexPath          = $imageIndex
                        outputDir          = $previewDir
                        sourceImageCount   = 1
                        exportedImageCount = 1
                    }
                },
                [ordered]@{
                    repoPath    = 'fixtures/Missing.vi'
                    status      = 'skipped'
                    changeTypes = @('deleted')
                    message     = 'missing path'
                    stats       = [ordered]@{
                        processed = 0
                        diffs     = 0
                    }
                }
            )
        }
        $summaryPayload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8

        $markdownPath = Join-Path $TestDrive 'history.md'
        $jsonOutPath = Join-Path $TestDrive 'history-output.json'

        $result = & $scriptPath -SummaryPath $summaryPath -MarkdownPath $markdownPath -OutputJsonPath $jsonOutPath

        $result.totals.targets | Should -Be 2
        $result.totals.diffs | Should -Be 2
        $result.totals.comparisons | Should -Be 4
        $result.totals.pairRows | Should -Be 2
        $result.totals.diffPairRows | Should -Be 1
        $result.totals.previewImages | Should -Be 1
        $result.totals.markdownTruncated | Should -BeFalse
        $result.totals.durationSeconds | Should -Be 12.5
        $result.totals.durationSamples | Should -Be 4
        $result.totals.timing.totalSeconds | Should -Be 3.75
        $result.kpi.signalRecall | Should -Be 1
        $result.kpi.noisePrecisionMasscompile | Should -BeNullOrEmpty
        $result.kpi.previewCoverage | Should -Be 0.5
        $result.kpi.timingP50Seconds | Should -Be 1.5
        $result.kpi.timingP95Seconds | Should -Be 2.25
        $result.kpi.commentTruncated | Should -BeFalse
        $result.kpi.truncationReason | Should -Be 'none'
        $result.pairTimeline.Count | Should -Be 2
        $result.previews.Count | Should -Be 1
        $result.markdown | Should -Match 'fixtures/Example.vi'
        $result.markdown | Should -Match 'diff'
        $result.markdown | Should -Match 'missing path'
        $result.markdown | Should -Match '### Commit Pair Timeline'
        $result.markdown | Should -Match 'signal'
        $result.markdown | Should -Match 'unknown'
        $result.markdown | Should -Match 'Timing'
        $result.markdown | Should -Match '\[signal\]'
        $result.markdown | Should -Match '\[fast 1\.5s\]'
        $result.markdown | Should -Match 'time: 12\.50s total'
        $result.markdown | Should -Match '### Mobile Preview'
        $result.markdown | Should -Match 'history-image-000.png'

        $written = Get-Content -LiteralPath $markdownPath -Raw -Encoding utf8
        $written.TrimEnd("`r","`n") | Should -Be $result.markdown

        $jsonEcho = Get-Content -LiteralPath $jsonOutPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 4
        $jsonEcho.markdown | Should -Be $result.markdown
    }

    It 'limits preview entries and truncates oversized markdown safely' {
        $resultsRoot = Join-Path $TestDrive 'pr-history-limits'
        $targetA = Join-Path $resultsRoot '01-A'
        $targetB = Join-Path $resultsRoot '02-B'
        New-Item -ItemType Directory -Path $targetA -Force | Out-Null
        New-Item -ItemType Directory -Path $targetB -Force | Out-Null

        $reportA = Join-Path $targetA 'history-report.html'
        $reportB = Join-Path $targetB 'history-report.html'
        Set-Content -LiteralPath $reportA -Value '<html></html>' -Encoding utf8
        Set-Content -LiteralPath $reportB -Value '<html></html>' -Encoding utf8

        $imageAPath = Join-Path $targetA 'previews/history-image-000.png'
        $imageBPath = Join-Path $targetB 'previews/history-image-000.png'
        New-Item -ItemType Directory -Path (Split-Path -Parent $imageAPath) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $imageBPath) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($imageAPath, @(0x01, 0x02))
        [System.IO.File]::WriteAllBytes($imageBPath, @(0x03, 0x04))

        $indexA = Join-Path $targetA 'vi-history-image-index.json'
        $indexB = Join-Path $targetB 'vi-history-image-index.json'
        [ordered]@{
            schema = 'pr-vi-history-image-index@v1'
            images = @(
                [ordered]@{
                    status   = 'saved'
                    savedPath= $imageAPath
                    alt      = 'A'
                }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $indexA -Encoding utf8
        [ordered]@{
            schema = 'pr-vi-history-image-index@v1'
            images = @(
                [ordered]@{
                    status   = 'saved'
                    savedPath= $imageBPath
                    alt      = 'B'
                }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $indexB -Encoding utf8

        $longMessage = ('x' * 1200)
        $summaryPath = Join-Path $TestDrive 'pr-history-limits-summary.json'
        $longRepoA = ('A' * 360) + '.vi'
        $longRepoB = ('B' * 360) + '.vi'
        [ordered]@{
            schema = 'pr-vi-history-summary@v1'
            resultsRoot = $resultsRoot
            targets = @(
                [ordered]@{
                    repoPath = $longRepoA
                    status = 'completed'
                    changeTypes = @('modified')
                    message = $longMessage
                    stats = [ordered]@{ processed = 1; diffs = 1 }
                    reportHtml = $reportA
                    reportImages = [ordered]@{
                        status = 'completed'
                        indexPath = $indexA
                    }
                },
                [ordered]@{
                    repoPath = $longRepoB
                    status = 'completed'
                    changeTypes = @('modified')
                    message = $longMessage
                    stats = [ordered]@{ processed = 1; diffs = 1 }
                    reportHtml = $reportB
                    reportImages = [ordered]@{
                        status = 'completed'
                        indexPath = $indexB
                    }
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8

        $result = & $scriptPath -SummaryPath $summaryPath -MaxPreviewImages 1 -MaxMarkdownLength 500
        $result.previews.Count | Should -Be 1
        $result.totals.previewImages | Should -Be 1
        $result.totals.markdownTruncated | Should -BeTrue
        $result.kpi.commentTruncated | Should -BeTrue
        $result.kpi.truncationReason | Should -Be 'max-markdown-length'
        $result.markdown.Length | Should -BeLessOrEqual 900
        $result.markdown | Should -Match 'Summary truncated for comment size safety'
    }

    It 'handles summaries with no preview entries' {
        $resultsRoot = Join-Path $TestDrive 'pr-history-no-previews'
        New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

        $summaryPath = Join-Path $TestDrive 'pr-history-no-previews-summary.json'
        [ordered]@{
            schema = 'pr-vi-history-summary@v1'
            resultsRoot = $resultsRoot
            targets = @(
                [ordered]@{
                    repoPath = 'fixtures/NoPreview.vi'
                    status = 'completed'
                    changeTypes = @('modified')
                    stats = [ordered]@{
                        processed = 1
                        diffs = 1
                    }
                }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

        $result = & $scriptPath -SummaryPath $summaryPath
        $result.totals.targets | Should -Be 1
        $result.totals.previewImages | Should -Be 0
        $result.previews.Count | Should -Be 0
        $result.markdown | Should -Not -Match '### Mobile Preview'
    }
}
