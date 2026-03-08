Describe 'Render-VIHistoryReport.ps1' -Tag 'Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Render-VIHistoryReport.ps1'
        $script:originalLocation = Get-Location
        Set-Location $script:repoRoot
    }

    AfterAll {
        if ($script:originalLocation) {
            Set-Location $script:originalLocation
        }
    }

    It 'renders bucket summaries into Markdown and HTML outputs' {
        $resultsRoot = Join-Path $TestDrive 'history-results'
        New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

        $reportDir = Join-Path $resultsRoot 'default/pair-01'
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $reportPath = Join-Path $reportDir 'compare-report.html'
        '<html></html>' | Set-Content -LiteralPath $reportPath -Encoding utf8

        $aggregateManifest = [ordered]@{
            schema            = 'vi-compare/history-suite@v1'
            generatedAt       = (Get-Date).ToString('o')
            targetPath        = 'fixtures/vi-attr/Base.vi'
            requestedStartRef = 'HEAD^'
            startRef          = 'HEAD'
            maxPairs          = 2
            resultsDir        = $resultsRoot
            requestedModes    = @('default')
            executedModes     = @('default')
            status            = 'ok'
            modes             = @(
                [ordered]@{
                    name         = 'default'
                    slug         = 'default'
                    reportFormat = 'html'
                    flags        = @('-nobd')
                    manifestPath = Join-Path $resultsRoot 'default' 'manifest.json'
                    resultsDir   = Join-Path $resultsRoot 'default'
                    status       = 'ok'
                    stats        = [ordered]@{
                        processed     = 2
                        diffs         = 1
                        signalDiffs   = 1
                        noiseCollapsed= 0
                        missing       = 0
                        categoryCounts= [ordered]@{ 'block-diagram' = 1 }
                        bucketCounts  = [ordered]@{ 'functional-behavior' = 1 }
                    }
                }
            )
            stats = [ordered]@{
                modes          = 1
                processed      = 2
                diffs          = 1
                signalDiffs    = 1
                noiseCollapsed = 0
                missing        = 0
                errors         = 0
                categoryCounts = [ordered]@{
                    'block-diagram' = 1
                    'attributes'    = 1
                }
                bucketCounts   = [ordered]@{
                    'functional-behavior' = 1
                    'metadata'            = 1
                }
            }
        }

        $modeDir = Join-Path $resultsRoot 'default'
        New-Item -ItemType Directory -Path $modeDir -Force | Out-Null
        $modeManifestPath = Join-Path $modeDir 'manifest.json'
        [ordered]@{
            schema      = 'vi-compare/history@v1'
            generatedAt = $aggregateManifest.generatedAt
            targetPath  = $aggregateManifest.targetPath
            mode        = 'default'
            slug        = 'default'
            stats       = $aggregateManifest.modes[0].stats
            comparisons = @()
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $modeManifestPath -Encoding utf8

        $context = [ordered]@{
            schema            = 'vi-compare/history-context@v1'
            generatedAt       = $aggregateManifest.generatedAt
            targetPath        = $aggregateManifest.targetPath
            requestedStartRef = $aggregateManifest.requestedStartRef
            startRef          = $aggregateManifest.startRef
            maxPairs          = 2
            comparisons       = @(
                [ordered]@{
                    mode  = 'default'
                    index = 1
                    base  = @{
                        full   = 'abc123456789'
                        short  = 'abc1234'
                        subject= 'Base commit'
                    }
                    head  = @{
                        full   = 'def987654321'
                        short  = 'def9876'
                        subject= 'Head commit'
                    }
                    lineage = [ordered]@{
                        type        = 'merge-parent'
                        parentIndex = 2
                        parentCount = 2
                        mergeCommit = 'feedfacefeed'
                        branchHead  = 'cafebabecafe'
                        depth       = 0
                    }
                    lineageLabel = 'Merge parent #2 @cafebabecafe'
                    result = [ordered]@{
                        diff                   = $true
                        duration_s             = 1.23
                        status                 = 'completed'
                        reportPath             = $reportPath
                        categories             = @('Block Diagram Functional', 'VI Attribute')
                        categoryDetails        = @(
                            @{ slug = 'block-diagram'; label = 'Block diagram'; classification = 'signal' },
                            @{ slug = 'attributes'; label = 'Attributes'; classification = 'neutral' }
                        )
                        categoryBuckets        = @('functional-behavior', 'metadata')
                        categoryBucketDetails  = @(
                            @{ slug = 'functional-behavior'; label = 'Functional behavior'; classification = 'signal' },
                            @{ slug = 'metadata'; label = 'Metadata'; classification = 'neutral' }
                        )
                    }
                    highlights = @('Block diagram change', 'Attributes: VI Attribute')
                }
            )
        }

        $manifestPath = Join-Path $TestDrive 'aggregate-manifest.json'
        $contextPath = Join-Path $TestDrive 'history-context.json'
        $aggregateManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $context | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contextPath -Encoding utf8

        $markdownPath = Join-Path $resultsRoot 'history-report.md'
        $htmlPath = Join-Path $resultsRoot 'history-report.html'
        $githubOutputPath = Join-Path $TestDrive 'github-output.txt'

        & $script:scriptPath `
            -ManifestPath $manifestPath `
            -HistoryContextPath $contextPath `
            -OutputDir $resultsRoot `
            -MarkdownPath $markdownPath `
            -EmitHtml `
            -HtmlPath $htmlPath `
            -GitHubOutputPath $githubOutputPath | Out-Null

        Test-Path -LiteralPath $markdownPath | Should -BeTrue
        Test-Path -LiteralPath $htmlPath | Should -BeTrue

        $markdown = Get-Content -LiteralPath $markdownPath -Raw
        $markdown | Should -Match 'Requested Modes: `default`'
        $markdown | Should -Match 'Executed Modes: `default`'
        $markdown | Should -Match '\| Metric \| Value \|'
        $markdown | Should -Match '\| Signal Diffs \|'
        $markdown | Should -Match '\| Buckets \|'
        $markdown | Should -Match 'Functional behavior'
        $markdown | Should -Match 'Metadata'
        $markdown | Should -Match '\| Mode \| Processed \| Diffs \| Signal \| Collapsed Noise \| Missing \| Categories \| Buckets \| Flags \|'
        $markdown | Should -Match '\| Mode \| Pair \| Lineage \| Base \| Head \| Diff \| Duration \(s\) \| Categories \| Buckets \| Report \| Highlights \|'

        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should -Match 'Requested modes'
        $html | Should -Match 'Executed modes'
        $html | Should -Match '<th>Signal</th>'
        $html | Should -Match '<th>Collapsed Noise</th>'
        $html | Should -Match '<th>Lineage</th>'
        $html | Should -Match '<th>Categories</th>'
        $html | Should -Match '<th>Buckets</th>'
        $html | Should -Match 'data-buckets='

        $outputLines = Get-Content -LiteralPath $githubOutputPath
    }
}
