Describe 'Summarize-VIStaging.ps1' -Tag 'Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Summarize-VIStaging.ps1'
        $script:originalLocation = Get-Location
        Set-Location $script:repoRoot
    }

    AfterAll {
        if ($script:originalLocation) {
            Set-Location $script:originalLocation
        }
    }

    It 'produces markdown summary for diff pair' {
        $compareRoot = Join-Path $TestDrive 'compare'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $html = @'
<!DOCTYPE html>
<html>
<body>
<div class="included-attributes">
  <ul class="inclusion-list">
    <li class="checked">Front Panel</li>
    <li class="checked">Block Diagram Functional</li>
    <li class="unchecked">Block Diagram Cosmetic</li>
    <li class="checked">VI Attribute</li>
  </ul>
</div>
<details open>
  <summary class="difference-heading">1. VI Attribute - Miscellaneous</summary>
  <ol class="detailed-description-list">
    <li class="diff-detail">Difference Type: VI icon</li>
  </ol>
</details>
<details open>
  <summary class="difference-heading">2. Block Diagram Functional - Nodes</summary>
</details>
</body>
</html>
'@
        $reportPath = Join-Path $pairDir 'compare-report.html'
        $html | Set-Content -LiteralPath $reportPath -Encoding utf8

        $compareEntry = @(
            [ordered]@{
                index      = 1
                changeType = 'modify'
                basePath   = 'VI1.vi'
                headPath   = 'VI1.vi'
                stagedBase = 'staged\Base.vi'
                stagedHead = 'staged\Head.vi'
                status     = 'diff'
                exitCode   = 1
                outputDir  = $pairDir
                reportPath = $reportPath
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $mdPath = Join-Path $TestDrive 'summary.md'
        $jsonPath = Join-Path $TestDrive 'summary.json'

        $result = & $script:scriptPath -CompareJson $compareJson -MarkdownPath $mdPath -SummaryJsonPath $jsonPath

        $result | Should -Not -BeNullOrEmpty
        $result.pairs.Count | Should -Be 1
        $result.pairs[0].diffCategories | Should -Contain 'VI Attribute'
        $result.pairs[0].diffCategories | Should -Contain 'Block Diagram Functional'
        $result.pairs[0].diffCategoryDetails | Should -Not -BeNullOrEmpty
        ($result.pairs[0].diffCategoryDetails | Where-Object { $_.slug -eq 'vi-attribute' }).Count | Should -Be 1
        ($result.pairs[0].diffCategoryDetails | Where-Object { $_.slug -eq 'block-diagram-functional' }).Count | Should -Be 1
        $result.pairs[0].diffBuckets | Should -Contain 'metadata'
        $result.pairs[0].diffBuckets | Should -Contain 'functional-behavior'
        ($result.pairs[0].diffBucketDetails | Where-Object { $_.slug -eq 'metadata' }).Count | Should -Be 1
        ($result.pairs[0].diffBucketDetails | Where-Object { $_.slug -eq 'functional-behavior' }).Count | Should -Be 1
        $result.pairs[0].includedAttributes.Count | Should -BeGreaterThan 0
        ($result.pairs[0].includedAttributes | Where-Object { $_.name -eq 'VI Attribute' }).value | Should -BeTrue
        (@($result.pairs[0].diffDetailPreview | Where-Object { $_ -match 'Difference Type: VI icon' })).Count | Should -BeGreaterThan 0
        $result.pairs[0].stagedBase | Should -Be 'staged\Base.vi'
        $result.pairs[0].stagedHead | Should -Be 'staged\Head.vi'
        $result.pairs[0].flagSummary | Should -Be '_none_'

        Test-Path -LiteralPath $mdPath | Should -BeTrue
        $markdown = Get-Content -LiteralPath $mdPath -Raw
        $markdown | Should -Match '\| Pair \| Status \| Diff Categories \| Included \| Report \| Flags \| Leak \|'
        $markdown | Should -Match 'VI Attribute'
        $markdown | Should -Match 'Difference Type: VI icon'
        $markdown | Should -Match 'Buckets:'
        $markdown | Should -Match 'Functional behavior'
        $markdown | Should -Match 'Metadata'

        Test-Path -LiteralPath $jsonPath | Should -BeTrue
        $jsonPayload = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 6
        $jsonPayload.totals.diff | Should -Be 1
        (@($jsonPayload.pairs[0].diffDetailPreview | Where-Object { $_ -match 'Difference Type: VI icon' })).Count | Should -BeGreaterThan 0
        $jsonPayload.pairs[0].diffCategoryDetails | Should -Not -BeNullOrEmpty
        $jsonPayload.totals.categoryCounts.'vi-attribute' | Should -Be 1
        $jsonPayload.totals.categoryCounts.'block-diagram-functional' | Should -Be 1
        $jsonPayload.totals.bucketCounts.'metadata' | Should -Be 1
        $jsonPayload.totals.bucketCounts.'functional-behavior' | Should -Be 1
        $jsonPayload.pairs[0].flagSummary | Should -Be '_none_'
    }

    It 'promotes diffDetected match entries to diff' {
        $compareRoot = Join-Path $TestDrive 'compare-detected'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $html = @'
<!DOCTYPE html>
<html>
<body>
<details open class="difference">
  <summary class="difference-heading">1. Block Diagram Cosmetic - Wires</summary>
  <ul>
    <li class="diff-detail">Wire repositioned</li>
  </ul>
</details>
</body>
</html>
'@
        $reportPath = Join-Path $pairDir 'compare-report.html'
        $html | Set-Content -LiteralPath $reportPath -Encoding utf8

        $compareEntry = @(
            [ordered]@{
                index        = 1
                changeType   = 'modify'
                basePath     = 'VI1.vi'
                headPath     = 'VI1.vi'
                status       = 'match'
                diffDetected = $true
                exitCode     = 0
                outputDir    = $pairDir
                reportPath   = $reportPath
                primaryMode  = 'full'
                modes        = @(
                    [ordered]@{
                        name         = 'full'
                        status       = 'match'
                        diffDetected = $true
                        exitCode     = 0
                        reportPath   = $reportPath
                        flags        = @()
                        replace      = $true
                    }
                )
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare-diffdetected.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $jsonPath = Join-Path $TestDrive 'summary-detected.json'
        $markdownPath = Join-Path $TestDrive 'summary-detected.md'

        $result = & $script:scriptPath -CompareJson $compareJson -SummaryJsonPath $jsonPath -MarkdownPath $markdownPath

        $result | Should -Not -BeNullOrEmpty
        $result.pairs.Count | Should -Be 1
        $result.pairs[0].status | Should -Be 'diff'
        $result.pairs[0].diffDetected | Should -BeTrue
        $result.pairs[0].modeSummaries | Should -Not -Be $null
        $result.pairs[0].modeSummaries.Count | Should -Be 1
        $result.pairs[0].modeSummaries[0].status | Should -Be 'diff'
        $result.pairs[0].modeSummaries[0].diffDetected | Should -BeTrue

        Test-Path -LiteralPath $jsonPath | Should -BeTrue
        $jsonPayload = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 6
        $jsonPayload.totals.diff | Should -Be 1
        $jsonPayload.totals.match | Should -Be 0
        $jsonPayload.pairs[0].status | Should -Be 'diff'
        $jsonPayload.pairs[0].diffDetected | Should -BeTrue
        $jsonPayload.pairs[0].modeSummaries[0].status | Should -Be 'diff'
        $jsonPayload.pairs[0].modeSummaries[0].diffDetected | Should -BeTrue

        Test-Path -LiteralPath $markdownPath | Should -BeTrue
        $markdown = Get-Content -LiteralPath $markdownPath -Raw
        $markdown | Should -Match '\| Pair 1 \(modif(?:y|ied)\) \| .*diff \|'
    }

    It 'classifies image-only report by diff details' {
        $compareRoot = Join-Path $TestDrive 'compare-image-only'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $fixturePath = Join-Path $script:repoRoot 'tests' 'fixtures' 'vi-report' 'image-only' 'compare-report.html'
        Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $pairDir 'compare-report.html')

        $compareEntry = @(
            [ordered]@{
                index        = 1
                changeType   = 'modified'
                basePath     = 'fixtures/vi-stage/bd-cosmetic/Base.vi'
                headPath     = 'fixtures/vi-stage/bd-cosmetic/Head.vi'
                outputDir    = $pairDir
                status       = 'diff'
                exitCode     = 1
                reportPath   = (Join-Path $pairDir 'compare-report.html')
                reportRelative = 'pair-01/compare-report.html'
            }
        )
        $compareJson = Join-Path $TestDrive 'vi-staging-compare-image.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $jsonPath = Join-Path $TestDrive 'summary-image.json'
        $markdownPath = Join-Path $TestDrive 'summary-image.md'

        $result = & $script:scriptPath -CompareJson $compareJson -SummaryJsonPath $jsonPath -MarkdownPath $markdownPath

        $result | Should -Not -BeNullOrEmpty
        $result.pairs.Count | Should -Be 1
        $pair = $result.pairs[0]
        $pair.diffDetected | Should -BeTrue
        $pair.diffCategoryDetails | Should -Not -BeNullOrEmpty
        ($pair.diffCategoryDetails | Where-Object { $_.slug -eq 'block-diagram-cosmetic' }).Count | Should -Be 1
        ($pair.diffCategoryDetails | Where-Object { $_.slug -eq 'front-panel' }).Count | Should -Be 1
        ($pair.diffCategoryDetails | Where-Object { $_.slug -eq 'vi-attribute' }).Count | Should -Be 1
        ($pair.diffCategoryDetails | Where-Object { $_.slug -eq 'icon' }).Count | Should -Be 1
        $pair.diffBucketDetails | Should -Not -BeNullOrEmpty
        ($pair.diffBucketDetails | Where-Object { $_.slug -eq 'ui-visual' }).Count | Should -BeGreaterThan 0
        ($pair.diffBucketDetails | Where-Object { $_.slug -eq 'metadata' }).Count | Should -BeGreaterThan 0

        $jsonPayload = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 6
        $jsonPayload.totals.categoryCounts.'block-diagram-cosmetic' | Should -Be 1
        $jsonPayload.totals.categoryCounts.'front-panel' | Should -Be 1
        $jsonPayload.totals.categoryCounts.'vi-attribute' | Should -Be 1
        $jsonPayload.totals.categoryCounts.'icon' | Should -Be 1
        $jsonPayload.totals.bucketCounts.'ui-visual' | Should -BeGreaterThan 0
        $jsonPayload.totals.bucketCounts.'metadata' | Should -BeGreaterThan 0

        $markdown = Get-Content -LiteralPath $markdownPath -Raw
        $markdown | Should -Match 'Block diagram \(cosmetic\)'
        $markdown | Should -Match 'Front panel'
        $markdown | Should -Match 'VI attribute'
    }

    It 'resolves report path when compare summary omits metadata' {
        $compareRoot = Join-Path $TestDrive 'compare'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $html = @'
<!DOCTYPE html>
<html>
<body>
<details open>
  <summary class="difference-heading">1. Block Diagram Functional - Nodes</summary>
  <ol class="detailed-description-list">
    <li class="diff-detail">Node changed</li>
  </ol>
</details>
</body>
</html>
'@
        $reportPath = Join-Path $pairDir 'compare-report.html'
        $html | Set-Content -LiteralPath $reportPath -Encoding utf8

        $capturePayload = @{ exitCode = 1 } | ConvertTo-Json
        $capturePayload | Set-Content -LiteralPath (Join-Path $pairDir 'lvcompare-capture.json') -Encoding utf8

        $compareEntry = @(
            [ordered]@{
                index      = 1
                changeType = 'modify'
                basePath   = 'VI1.vi'
                headPath   = 'VI1.vi'
                outputDir  = $pairDir
                status     = 'diff'
                exitCode   = 1
                reportPath = $null
                capturePath= $null
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare-missing.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $result = & $script:scriptPath -CompareJson $compareJson

        $result | Should -Not -BeNullOrEmpty
        $result.pairs.Count | Should -Be 1
        ($result.pairs[0].reportRelative.Replace('\','/')) | Should -Be 'pair-01/compare-report.html'
        $result.pairs[0].diffCategories | Should -Contain 'Block Diagram Functional'
        $result.pairs[0].diffCategoryDetails[0].slug | Should -Be 'block-diagram-functional'
    }

    It 'prefers capture-derived custom report artifacts over fixed compare-report leaf guesses' {
        $compareRoot = Join-Path $TestDrive 'compare-custom'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $reportPath = Join-Path $pairDir 'diff-report-Initialization_UserEvents.vi.html'
        @'
<!DOCTYPE html>
<html>
<body>
<details open>
  <summary class="difference-heading">1. VI Attribute - Miscellaneous</summary>
  <ol class="detailed-description-list">
    <li class="diff-detail">Difference Type: VI icon</li>
  </ol>
</details>
</body>
</html>
'@ | Set-Content -LiteralPath $reportPath -Encoding utf8

        $capturePath = Join-Path $pairDir 'lvcompare-capture.json'
        @'
{
  "schema": "lvcompare-capture-v1",
  "out": {
    "reportHtml": "./diff-report-Initialization_UserEvents.vi.html"
  },
  "cli": {
    "reportPath": "./diff-report-Initialization_UserEvents.vi.html"
  }
}
'@ | Set-Content -LiteralPath $capturePath -Encoding utf8

        $compareEntry = @(
            [ordered]@{
                index      = 1
                changeType = 'modify'
                basePath   = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
                headPath   = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
                outputDir  = $pairDir
                status     = 'diff'
                exitCode   = 1
                reportPath = $null
                capturePath= $null
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare-custom-report.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $result = & $script:scriptPath -CompareJson $compareJson

        $result | Should -Not -BeNullOrEmpty
        $result.pairs.Count | Should -Be 1
        $result.pairs[0].reportPath | Should -Be $reportPath
        ($result.pairs[0].reportRelative.Replace('\','/')) | Should -Be 'pair-01/diff-report-Initialization_UserEvents.vi.html'
        $result.pairs[0].diffCategories | Should -Contain 'VI Attribute'
    }

    It 'renders consolidated html with valid local artifact links' {
        $compareRoot = Join-Path $TestDrive 'compare-html'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $reportPath = Join-Path $pairDir 'compare-report.html'
        @'
<!DOCTYPE html>
<html>
<body>
<details open>
  <summary class="difference-heading">1. Front Panel - Panel</summary>
  <ol class="detailed-description-list">
    <li class="diff-detail">Control moved</li>
  </ol>
</details>
</body>
</html>
'@ | Set-Content -LiteralPath $reportPath -Encoding utf8

        $capturePath = Join-Path $pairDir 'lvcompare-capture.json'
        '{"exitCode":1,"status":"diff"}' | Set-Content -LiteralPath $capturePath -Encoding utf8

        $compareEntry = @(
            [ordered]@{
                index      = 1
                changeType = 'modify'
                basePath   = 'fixtures/vi-stage/fp-cosmetic/Base.vi'
                headPath   = 'fixtures/vi-stage/fp-cosmetic/Head.vi'
                status     = 'diff'
                exitCode   = 1
                outputDir  = $pairDir
                reportPath = $reportPath
                capturePath= $capturePath
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare-html.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $htmlPath = Join-Path $TestDrive 'vi-compare-summary.html'
        $result = & $script:scriptPath -CompareJson $compareJson -HtmlPath $htmlPath

        Test-Path -LiteralPath $htmlPath -PathType Leaf | Should -BeTrue
        $result.htmlPath | Should -Be ([System.IO.Path]::GetFullPath($htmlPath))

        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should -Match '<a href="[^"]+">compare-report</a>'
        $html | Should -Match '<a href="[^"]+">capture-json</a>'

        $hrefMatches = [regex]::Matches($html, 'href="(?<href>[^"]+)"')
        $hrefMatches.Count | Should -BeGreaterThan 0
        $htmlDir = Split-Path -Parent $htmlPath
        foreach ($match in $hrefMatches) {
            $href = [string]$match.Groups['href'].Value
            if ([string]::IsNullOrWhiteSpace($href)) { continue }
            if ($href -match '^(?i)https?://') { continue }
            if ($href.StartsWith('#')) { continue }
            $decodedHref = [Uri]::UnescapeDataString($href)
            $relativePath = $decodedHref -replace '/', [System.IO.Path]::DirectorySeparatorChar
            $resolvedTarget = [System.IO.Path]::GetFullPath((Join-Path $htmlDir $relativePath))
            Test-Path -LiteralPath $resolvedTarget -PathType Leaf | Should -BeTrue
        }
    }

    It 'handles missing report gracefully' {
        $compareEntry = @(
            [ordered]@{
                index      = 2
                changeType = 'modify'
                basePath   = 'VI2.vi'
                headPath   = 'VI2.vi'
                status     = 'skipped'
                exitCode   = $null
                outputDir  = (Join-Path $TestDrive 'missing')
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare-empty.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $result = & $script:scriptPath -CompareJson $compareJson

        $result.pairs.Count | Should -Be 1
        $result.pairs[0].status | Should -Be 'skipped'
        $result.pairs[0].diffCategories.Count | Should -Be 0
        $result.pairs[0].diffCategoryDetails.Count | Should -Be 0
        $result.pairs[0].diffBuckets.Count | Should -Be 0
        $result.pairs[0].diffBucketDetails.Count | Should -Be 0
        $result.markdown | Should -Match 'Totals'
    }

    It 'tracks leak warnings in totals and markdown' {
        $compareRoot = Join-Path $TestDrive 'compare'
        $pairDir = Join-Path $compareRoot 'pair-01'
        New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

        $compareEntry = @(
            [ordered]@{
                index          = 1
                changeType     = 'modify'
                basePath       = 'VI1.vi'
                headPath       = 'VI1.vi'
                status         = 'diff'
                exitCode       = 1
                outputDir      = $pairDir
                reportPath     = $null
                leakWarning    = $true
                leakLvcompare  = 3
                leakLabVIEW    = 1
                leakPath       = Join-Path $pairDir 'compare-leak.json'
            }
        )

        $compareJson = Join-Path $TestDrive 'vi-staging-compare-leak.json'
        $compareEntry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compareJson -Encoding utf8

        $result = & $script:scriptPath -CompareJson $compareJson

        $result | Should -Not -BeNullOrEmpty
        $result.totals.leakWarnings | Should -Be 1
        $result.pairs.Count | Should -Be 1
        $result.pairs[0].leakWarning | Should -BeTrue
        $result.pairs[0].leakLvcompare | Should -Be 3
        $result.pairs[0].leakLabVIEW | Should -Be 1
        $result.markdown.Contains('lv=3') | Should -BeTrue
        $result.markdown.Contains('lab=1') | Should -BeTrue
        $result.markdown | Should -Match 'Totals'
    }
}
