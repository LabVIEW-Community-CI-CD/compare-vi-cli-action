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
            Set-Content -LiteralPath (Join-Path $Arguments.ResultsDir 'history-report.html') -Value '<html></html>' -Encoding utf8
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

        $target = $result.targets[0]
        $target.status | Should -Be 'completed'
        $target.stats.processed | Should -Be 3
        $target.stats.diffs | Should -Be 1

        Test-Path -LiteralPath $result.resultsRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $result.targets[0].manifest -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $result.targets[0].reportMd -PathType Leaf | Should -BeTrue
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
        $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 4
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
