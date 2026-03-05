$ErrorActionPreference = 'Stop'

Describe 'Prepare-FixtureViDiffs.ps1' -Tag 'IconEditor','VICompare','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name prepareScript -Value (Join-Path $repoRoot 'tools/icon-editor/Prepare-FixtureViDiffs.ps1')
        Set-Variable -Scope Script -Name describeScript -Value (Join-Path $repoRoot 'tools/icon-editor/Describe-IconEditorFixture.ps1')
        Set-Variable -Scope Script -Name currentFixture -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/ni_icon_editor-1.4.1.948.vip')
        Set-Variable -Scope Script -Name baselineFixture -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/ni_icon_editor-1.4.1.794.vip')
        Set-Variable -Scope Script -Name baselineManifestPath -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/fixture-manifest-1.4.1.794.json')
    }

    It 'emits requests when baseline manifest hash diverges' {
        $reportPath = Join-Path $TestDrive 'fixture-report.json'
        $summary = & $script:describeScript -FixturePath $script:currentFixture
        $summary | Should -Not -BeNullOrEmpty
        $summary.fixtureOnlyAssets += [ordered]@{
            category  = 'resource'
            name      = 'plugins\NIIconEditor\Miscellaneous\Icon Editor\MenuSelection(User).vi'
            path      = Join-Path $TestDrive 'MenuSelection(User).vi'
            sizeBytes = 1024
            hash      = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }
        $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

        $baselineManifest = Get-Content -LiteralPath $script:baselineManifestPath -Raw | ConvertFrom-Json -Depth 6
        $target = $baselineManifest.entries | Where-Object { $_.path -eq 'tests\Unit Tests\Editor Position\Adjust Position.vi' } | Select-Object -First 1
        $target | Should -Not -BeNullOrEmpty
        $target.hash = '0000000000000000000000000000000000000000000000000000000000000000'

        $resourceAsset = $summary.fixtureOnlyAssets | Where-Object { $_.category -eq 'resource' -and $_.name -like '*.vi' } | Select-Object -First 1
        $resourceAsset | Should -Not -BeNullOrEmpty
        $resourcePath = Join-Path 'resource' $resourceAsset.name
        $resourceEntry = [ordered]@{
            key       = ('resource:' + $resourcePath).ToLower()
            category  = 'resource'
            path      = $resourcePath
            sizeBytes = ($resourceAsset.sizeBytes ?? 0)
            hash      = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
        }
        $baselineManifest.entries = @(
            $baselineManifest.entries | Where-Object { $_.key -ne $resourceEntry.key }
        )
        $baselineManifest.entries += $resourceEntry

        $baselineManifest.generatedAt = (Get-Date).ToString('o')
        $tempManifestPath = Join-Path $TestDrive 'baseline-manifest.json'
        $baselineManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempManifestPath -Encoding utf8

        $outputDir = Join-Path $TestDrive 'vi-diff'
        & $script:prepareScript `
            -ReportPath $reportPath `
            -BaselineManifestPath $tempManifestPath `
            -BaselineFixturePath $script:baselineFixture `
            -OutputDir $outputDir | Out-Null

        $requestsPath = Join-Path $outputDir 'vi-diff-requests.json'
        Test-Path -LiteralPath $requestsPath | Should -BeTrue

        $requests = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -Depth 6
        $requests.count | Should -BeGreaterThan 0
        $testRequest = $requests.requests | Where-Object { $_.category -eq 'test' } | Select-Object -First 1
        $testRequest | Should -Not -BeNullOrEmpty
        $testRequest.base | Should -Not -BeNullOrEmpty
        $testRequest.head | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $testRequest.base | Should -BeTrue
        Test-Path -LiteralPath $testRequest.head | Should -BeTrue

        $resourceRequest = $requests.requests | Where-Object { $_.category -eq 'resource' -and $_.relPath -eq $resourcePath } | Select-Object -First 1
        $resourceRequest | Should -Not -BeNullOrEmpty
        $resourceRequest.head | Should -Not -BeNullOrEmpty
    }
}
