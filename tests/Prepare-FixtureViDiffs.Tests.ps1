$ErrorActionPreference = 'Stop'

Describe 'Prepare-FixtureViDiffs.ps1' -Tag 'IconEditor','VICompare','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name prepareScript -Value (Join-Path $repoRoot 'tools/icon-editor/Prepare-FixtureViDiffs.ps1')
        Set-Variable -Scope Script -Name describeScript -Value (Join-Path $repoRoot 'tools/icon-editor/Describe-IconEditorFixture.ps1')
        Set-Variable -Scope Script -Name currentFixture -Value $env:ICON_EDITOR_FIXTURE_PATH
        Set-Variable -Scope Script -Name baselineFixture -Value $env:ICON_EDITOR_BASELINE_FIXTURE_PATH
        Set-Variable -Scope Script -Name baselineManifestPath -Value $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
    }

    function New-FixtureDiffSetup {
        param(
            [Parameter(Mandatory)][string]$OutputDir
        )

        $reportPath = Join-Path $TestDrive ("fixture-report-{0}.json" -f ([guid]::NewGuid().ToString('n')))
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

        $tempManifestPath = Join-Path $TestDrive ("baseline-manifest-{0}.json" -f ([guid]::NewGuid().ToString('n')))
        $baselineManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempManifestPath -Encoding utf8

        return [pscustomobject]@{
            ReportPath           = $reportPath
            BaselineManifestPath = $tempManifestPath
            OutputDir            = $OutputDir
            ResourceRelPath      = $resourcePath
        }
    }

    It 'emits requests when baseline manifest hash diverges' {
        if (-not $script:currentFixture -or -not (Test-Path -LiteralPath $script:currentFixture -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_FIXTURE_PATH not supplied; skipping VI diff request test.'
            return
        }
        if (-not $script:baselineFixture -or -not (Test-Path -LiteralPath $script:baselineFixture -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_BASELINE_FIXTURE_PATH not supplied; skipping VI diff request test.'
            return
        }
        if (-not $script:baselineManifestPath -or -not (Test-Path -LiteralPath $script:baselineManifestPath -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_BASELINE_MANIFEST_PATH not supplied; skipping VI diff request test.'
            return
        }

        $context = New-FixtureDiffSetup -OutputDir (Join-Path $TestDrive 'vi-diff')
        $outputDir = $context.OutputDir
        & $script:prepareScript `
            -ReportPath $context.ReportPath `
            -BaselineManifestPath $context.BaselineManifestPath `
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

        $resourceRequest = $requests.requests | Where-Object { $_.category -eq 'resource' -and $_.relPath -eq $context.ResourceRelPath } | Select-Object -First 1
        $resourceRequest | Should -Not -BeNullOrEmpty
        $resourceRequest.head | Should -Not -BeNullOrEmpty
    }

    It 'uses baseline environment paths when parameters are omitted' {
        if (-not $script:currentFixture -or -not (Test-Path -LiteralPath $script:currentFixture -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_FIXTURE_PATH not supplied; skipping VI diff request test.'
            return
        }
        if (-not $script:baselineFixture -or -not (Test-Path -LiteralPath $script:baselineFixture -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_BASELINE_FIXTURE_PATH not supplied; skipping VI diff request test.'
            return
        }
        if (-not $script:baselineManifestPath -or -not (Test-Path -LiteralPath $script:baselineManifestPath -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_BASELINE_MANIFEST_PATH not supplied; skipping VI diff request test.'
            return
        }

        $context = New-FixtureDiffSetup -OutputDir (Join-Path $TestDrive 'vi-diff-env')

        $originalBaselineFixture = $env:ICON_EDITOR_BASELINE_FIXTURE_PATH
        $originalBaselineManifest = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
        try {
            $env:ICON_EDITOR_BASELINE_FIXTURE_PATH = $script:baselineFixture
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $context.BaselineManifestPath

            & $script:prepareScript `
                -ReportPath $context.ReportPath `
                -OutputDir $context.OutputDir `
                -ResourceOverlayRoot $null | Out-Null

            $requestsPath = Join-Path $context.OutputDir 'vi-diff-requests.json'
            Test-Path -LiteralPath $requestsPath | Should -BeTrue
            $requests = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -Depth 6
            $requests.count | Should -BeGreaterThan 0

            $resourceRequest = $requests.requests | Where-Object { $_.category -eq 'resource' -and $_.relPath -eq $context.ResourceRelPath } | Select-Object -First 1
            $resourceRequest | Should -Not -BeNullOrEmpty
            $resourceRequest.base | Should -Not -BeNullOrEmpty
            $resourceRequest.head | Should -Not -BeNullOrEmpty
        }
        finally {
            if ($null -ne $originalBaselineFixture) {
                $env:ICON_EDITOR_BASELINE_FIXTURE_PATH = $originalBaselineFixture
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_FIXTURE_PATH -ErrorAction SilentlyContinue
            }
            if ($null -ne $originalBaselineManifest) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaselineManifest
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }
}
