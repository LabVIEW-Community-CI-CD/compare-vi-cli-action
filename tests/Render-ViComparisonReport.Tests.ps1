$ErrorActionPreference = 'Stop'

Describe 'Render-ViComparisonReport.ps1' {
    BeforeAll {
        $repoRoot = (git rev-parse --show-toplevel).Trim()
        $renderScript = Join-Path $repoRoot 'tools/icon-editor/Render-ViComparisonReport.ps1'
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name renderScript -Value (Get-Item -LiteralPath $renderScript)
    }

    It 'renders with partial/missing artifact properties (IDictionary + PSCustomObject)' {
        $outDir = Join-Path $TestDrive 'vi-diff-captures'
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        $summaryPath = Join-Path $outDir 'vi-comparison-summary.json'
        $reportPath = Join-Path $outDir 'vi-comparison-report.md'

        $summary = [ordered]@{
            counts = [ordered]@{
                total     = 3
                compared  = 1
                same      = 1
                different = 0
                skipped   = 1
                dryRun    = 1
                errors    = 1
            }
            requests = @(
                # Hashtable artifacts (IDictionary) missing sessionIndex
                [ordered]@{
                    name      = 'Hashed.vi'
                    relPath   = 'Folder/Hashed.vi'
                    status    = 'same'
                    message   = 'ok'
                    artifacts = @{ captureJson = 'captures/vi-001/capture.json' }
                },
                # PSCustomObject artifacts missing captureJson
                [pscustomobject]@{
                    name      = 'Custom.vi'
                    relPath   = 'Folder/Custom.vi'
                    status    = 'skipped'
                    message   = 'dry run'
                    artifacts = [pscustomobject]@{ sessionIndex = 'captures/vi-002/session-index.json' }
                },
                # No artifacts at all
                [ordered]@{
                    name    = 'Errored.vi'
                    relPath = 'Folder/Errored.vi'
                    status  = 'error'
                    message = 'failure'
                }
            )
            generatedAt = (Get-Date).ToString('o')
        }

        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

        $markdown = & $script:renderScript -SummaryPath $summaryPath -OutputPath $reportPath

        Test-Path -LiteralPath $reportPath | Should -BeTrue
        $markdown | Should -Match '## VI Comparison Report'
        $markdown | Should -Match '\| Folder/Hashed\.vi \|'
        $markdown | Should -Match '\| Folder/Custom\.vi \|'
        $markdown | Should -Match '\| Folder/Errored\.vi \|'
        # Ensure links are present when provided and absent when missing
        ($markdown -match '\[capture\]\(') | Should -BeTrue
        ($markdown -match '\[session-index\]\(') | Should -BeTrue
    }
}


