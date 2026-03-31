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
            branchBudget      = [ordered]@{
                sourceBranchRef = 'feature/history-source'
                baselineRef     = 'develop'
                maxCommitCount  = 64
                commitCount     = 3
                status          = 'ok'
                reason          = 'within-limit'
            }
            resultsDir        = $resultsRoot
            requestedModes    = @('default', 'attributes')
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
            branchBudget      = $aggregateManifest.branchBudget
            comparisons       = @(
                [ordered]@{
                    mode  = 'default'
                    index = 1
                    base  = @{
                        full   = 'aaa111111111'
                        short  = 'aaa1111'
                        subject= 'Clean base commit'
                        date   = '2026-03-09T09:00:00Z'
                    }
                    head  = @{
                        full   = 'bbb222222222'
                        short  = 'bbb2222'
                        subject= 'Clean head commit'
                        date   = '2026-03-10T10:00:00Z'
                    }
                    lineage = [ordered]@{
                        type        = 'touch-history'
                        parentIndex = 1
                        parentCount = 1
                        mergeCommit = $null
                        branchHead  = $null
                        depth       = 0
                    }
                    lineageLabel = 'Touch history'
                    result = [ordered]@{
                        diff                   = $false
                        duration_s             = 0.45
                        status                 = 'completed'
                        reportPath             = $reportPath
                        categories             = @()
                        categoryDetails        = @()
                        categoryBuckets        = @()
                        categoryBucketDetails  = @()
                    }
                    highlights = @()
                }
                [ordered]@{
                    mode  = 'default'
                    index = 2
                    base  = @{
                        full   = 'abc123456789'
                        short  = 'abc1234'
                        subject= 'Base commit'
                        date   = '2026-03-11T11:00:00Z'
                    }
                    head  = @{
                        full   = 'def987654321'
                        short  = 'def9876'
                        subject= 'Head commit'
                        date   = '2026-03-12T12:00:00Z'
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
        $stepSummaryPath = Join-Path $TestDrive 'github-summary.md'

        & $script:scriptPath `
            -ManifestPath $manifestPath `
            -HistoryContextPath $contextPath `
            -OutputDir $resultsRoot `
            -MarkdownPath $markdownPath `
            -EmitHtml `
            -HtmlPath $htmlPath `
            -GitHubOutputPath $githubOutputPath `
            -StepSummaryPath $stepSummaryPath | Out-Null

        Test-Path -LiteralPath $markdownPath | Should -BeTrue
        Test-Path -LiteralPath $htmlPath | Should -BeTrue
        Test-Path -LiteralPath $stepSummaryPath | Should -BeTrue

        $markdown = Get-Content -LiteralPath $markdownPath -Raw
        $markdown | Should -Match 'Source Branch: `feature/history-source`'
        $markdown | Should -Match 'Source Branch Budget: `3/64; baseline: develop; status: ok`'
        $markdown | Should -Match 'Requested Modes: `default, attributes`'
        $markdown | Should -Match 'Executed Modes: `default`'
        $markdown | Should -Match '\| Metric \| Value \|'
        $markdown | Should -Match '\| Signal Diffs \|'
        $markdown | Should -Match '\| Buckets \|'
        $markdown | Should -Match 'Functional behavior'
        $markdown | Should -Match 'Metadata'
        $markdown | Should -Match '## Observed interpretation'
        $markdown | Should -Match '\| Coverage Class \| `catalog-partial` \|'
        $markdown | Should -Match '\| Mode Sensitivity \| `single-mode-observed` \|'
        $markdown | Should -Match '\| Outcome Labels \| `clean`, `signal-diff` \|'
        $markdown | Should -Match '## Decision guidance'
        $markdown | Should -Match 'Decision statement'
        $markdown | Should -Match 'Start at pair 2; it is the newest meaningful change'
        $markdown | Should -Match 'Review first'
        $markdown | Should -Match 'Review sequence'
        $markdown | Should -Match 'pair 2 \(abc1234 \(Base commit; 2026-03-11T11:00:00\+00:00\) -> def9876 \(Head commit; 2026-03-12T12:00:00\+00:00\)\)'
        $markdown | Should -Match 'pair 2 \(Base commit @ 2026-03-11T11:00:00\+00:00 -> Head commit @ 2026-03-12T12:00:00\+00:00\)'
        $markdown | Should -Match '\| Mode \| Processed \| Diffs \| Signal \| Collapsed Noise \| Missing \| Categories \| Buckets \| Flags \|'
        $markdown | Should -Match '\| Mode \| Pair \| Lineage \| Base \| Head \| Diff \| Duration \(s\) \| Categories \| Buckets \| Report \| Highlights \|'
        $markdown | Should -Match 'aaa1111 \(Clean base commit; 2026-03-09T09:00:00\+00:00\)'
        $markdown | Should -Match 'Touch history'

        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should -Match 'Source branch'
        $html | Should -Match 'feature/history-source'
        $html | Should -Match 'Source branch budget'
        $html | Should -Match '3/64; baseline: develop; status: ok'
        $html | Should -Match 'Observed interpretation'
        $html | Should -Match 'Requested modes'
        $html | Should -Match 'Executed modes'
        $html | Should -Match 'Coverage Class'
        $html | Should -Match 'catalog-partial'
        $html | Should -Match 'Mode Sensitivity'
        $html | Should -Match 'single-mode-observed'
        $html | Should -Match 'Outcome Labels'
        $html | Should -Match '<code>clean</code>, <code>signal-diff</code>'
        $html | Should -Match 'Review first'
        $html | Should -Match 'Decision statement'
        $html | Should -Match 'Start at pair 2; it is the newest meaningful change'
        $html | Should -Match 'Review sequence'
        $html | Should -Match 'pair 2 \(abc1234 \(Base commit; 2026-03-11T11:00:00\+00:00\) -&gt; def9876 \(Head commit; 2026-03-12T12:00:00\+00:00\)\)'
        $html | Should -Match 'pair 2 \(Base commit @ 2026-03-11T11:00:00\+00:00 -&gt; Head commit @ 2026-03-12T12:00:00\+00:00\)'
        $html | Should -Match '<th>Signal</th>'
        $html | Should -Match '<th>Collapsed Noise</th>'
        $html | Should -Match '<th>Lineage</th>'
        $html | Should -Match '<th>Categories</th>'
        $html | Should -Match '<th>Buckets</th>'
        $html | Should -Match 'Touch history'
        $html | Should -Match 'data-buckets='
        $html | Should -Match 'Functional behavior \(1\)'

        $stepSummary = Get-Content -LiteralPath $stepSummaryPath -Raw
        $stepSummary | Should -Match '## Observed interpretation'
        $stepSummary | Should -Match '\| Coverage Class \| `catalog-partial` \|'
        $stepSummary | Should -Match '\| Mode Sensitivity \| `single-mode-observed` \|'
        $stepSummary | Should -Match '\| Outcome Labels \| `clean`, `signal-diff` \|'
        $stepSummary | Should -Match '## Mode overview'
        $stepSummary | Should -Match '\| Mode \| Processed \| Diffs \| Signal \| Collapsed Noise \| Missing \| Categories \| Buckets \| Flags \|'
        $stepSummary | Should -Match 'Functional behavior \(1\)'
        $stepSummary | Should -Match 'Metadata _\(neutral\)_ \(1\)'
        $stepSummary | Should -Match '## Artifacts'
        $stepSummary | Should -Match 'history-report\.md'

        $outputLines = Get-Content -LiteralPath $githubOutputPath
        $historySummaryLine = $outputLines | Where-Object { $_ -like 'history-summary-json=*' } | Select-Object -First 1
        $historySummaryLine | Should -Not -BeNullOrEmpty
        $historySummaryPath = (($historySummaryLine -split '=', 2)[1]).Trim()
        Test-Path -LiteralPath $historySummaryPath | Should -BeTrue
        $historySummary = Get-Content -LiteralPath $historySummaryPath -Raw | ConvertFrom-Json -Depth 12 -DateKind String
        $historySummary.target.sourceBranchRef | Should -Be 'feature/history-source'
        $historySummary.target.branchBudget.maxCommitCount | Should -Be 64
        $historySummary.target.branchBudget.commitCount | Should -Be 3
        $historySummary.decisionGuidance.latestPair.baseDate | Should -Be '2026-03-09T09:00:00+00:00'
        $historySummary.decisionGuidance.latestPair.headDate | Should -Be '2026-03-10T10:00:00+00:00'
        $historySummary.decisionGuidance.decisionStatement | Should -Be 'Start at pair 2; it is the newest meaningful change. It touches Functional behavior.'
        $historySummary.decisionGuidance.latestSignalPair.index | Should -Be 2
        $historySummary.decisionGuidance.latestSignalPair.baseSubject | Should -Be 'Base commit'
        $historySummary.decisionGuidance.latestSignalPair.headSubject | Should -Be 'Head commit'
        $historySummary.decisionGuidance.latestSignalPair.baseDate | Should -Be '2026-03-11T11:00:00+00:00'
        $historySummary.decisionGuidance.latestSignalPair.headDate | Should -Be '2026-03-12T12:00:00+00:00'
        @($historySummary.decisionGuidance.reviewSequence).Count | Should -Be 1
        $historySummary.decisionGuidance.reviewSequence[0].index | Should -Be 2
        $historySummary.decisionGuidance.reviewSequence[0].baseSubject | Should -Be 'Base commit'
        $historySummary.decisionGuidance.reviewSequence[0].headSubject | Should -Be 'Head commit'
        $historySummary.decisionGuidance.reviewSequence[0].baseDate | Should -Be '2026-03-11T11:00:00+00:00'
        $historySummary.decisionGuidance.reviewSequence[0].headDate | Should -Be '2026-03-12T12:00:00+00:00'
    }

    It 'preserves branch budget numeric fields when the source object is a hashtable' {
        $resultsRoot = Join-Path $TestDrive 'history-results-hashtable'
        New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
        $manifestPath = Join-Path $resultsRoot 'aggregate-manifest.json'
        $contextPath = Join-Path $resultsRoot 'history-context.json'
        @'
{
  "schema": "vi-compare/history-suite@v1",
  "generatedAt": "2026-03-10T00:00:00Z",
  "targetPath": "fixtures/vi-attr/Base.vi",
  "requestedStartRef": "HEAD^",
  "startRef": "HEAD",
  "requestedModes": ["default"],
  "executedModes": ["default"],
  "stats": {
    "modes": 1,
    "processed": 0,
    "diffs": 0,
    "signalDiffs": 0,
    "noiseCollapsed": 0,
    "missing": 0,
    "errors": 0,
    "categoryCounts": {},
    "bucketCounts": {}
  },
  "modes": [
    {
      "name": "default",
      "slug": "default",
      "status": "ok",
      "flags": [],
      "manifestPath": "default/manifest.json",
      "resultsDir": "default",
      "stats": {
        "processed": 0,
        "diffs": 0,
        "signalDiffs": 0,
        "noiseCollapsed": 0,
        "missing": 0,
        "errors": 0,
        "categoryCounts": {},
        "bucketCounts": {}
      }
    }
  ],
  "status": "ok"
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
        @'
{
  "schema": "vi-compare/history-context@v1",
  "generatedAt": "2026-03-10T00:00:00Z",
  "targetPath": "fixtures/vi-attr/Base.vi",
  "requestedStartRef": "HEAD^",
  "startRef": "HEAD",
  "comparisons": []
}
'@ | Set-Content -LiteralPath $contextPath -Encoding utf8
        $markdownPath = Join-Path $resultsRoot 'history-report.md'

        . $script:scriptPath `
            -ManifestPath $manifestPath `
            -HistoryContextPath $contextPath `
            -OutputDir $resultsRoot `
            -MarkdownPath $markdownPath

        $facade = New-BranchBudgetFacade -BranchBudget @{
            sourceBranchRef = 'feature/history-source'
            baselineRef = 'main'
            maxCommitCount = 64
            commitCount = 3
            status = 'ok'
            reason = 'within-limit'
        }

        $facade.sourceBranchRef | Should -Be 'feature/history-source'
        $facade.baselineRef | Should -Be 'main'
        $facade.maxCommitCount | Should -Be 64
        $facade.commitCount | Should -Be 3
        $facade.status | Should -Be 'ok'
        $facade.reason | Should -Be 'within-limit'
    }
}
