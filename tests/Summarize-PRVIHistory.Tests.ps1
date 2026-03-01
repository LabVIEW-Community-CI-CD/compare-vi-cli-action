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
            targets     = @(
                [ordered]@{
                    repoPath    = 'fixtures/Example.vi'
                    status      = 'completed'
                    changeTypes = @('modified','renamed')
                    stats       = [ordered]@{
                        processed = 4
                        diffs     = 2
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
        $result.totals.previewImages | Should -Be 1
        $result.previews.Count | Should -Be 1
        $result.markdown | Should -Match 'fixtures/Example.vi'
        $result.markdown | Should -Match 'diff'
        $result.markdown | Should -Match 'missing path'
        $result.markdown | Should -Match '### Mobile Preview'
        $result.markdown | Should -Match 'history-image-000.png'

        $written = Get-Content -LiteralPath $markdownPath -Raw -Encoding utf8
        $written.TrimEnd("`r","`n") | Should -Be $result.markdown

        $jsonEcho = Get-Content -LiteralPath $jsonOutPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 4
        $jsonEcho.markdown | Should -Be $result.markdown
    }
}
