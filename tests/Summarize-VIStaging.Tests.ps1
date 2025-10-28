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
        $result.pairs[0].includedAttributes.Count | Should -BeGreaterThan 0
        ($result.pairs[0].includedAttributes | Where-Object { $_.name -eq 'VI Attribute' }).value | Should -BeTrue
        $result.pairs[0].stagedBase | Should -Be 'staged\Base.vi'
        $result.pairs[0].stagedHead | Should -Be 'staged\Head.vi'

        Test-Path -LiteralPath $mdPath | Should -BeTrue
        (Get-Content -LiteralPath $mdPath -Raw) | Should -Match 'VI Attribute'

        Test-Path -LiteralPath $jsonPath | Should -BeTrue
        $jsonPayload = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 6
        $jsonPayload.totals.diff | Should -Be 1
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
        $result.markdown | Should -Match 'Totals'
    }
}
