Describe 'Extract-VIHistoryReportImages.ps1' -Tag 'Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Extract-VIHistoryReportImages.ps1'
        $script:originalLocation = Get-Location
        Set-Location $script:repoRoot
    }

    AfterAll {
        if ($script:originalLocation) {
            Set-Location $script:originalLocation
        }
    }

    It 'extracts embedded images with deterministic names and writes index contract' {
        $reportDir = Join-Path $TestDrive 'history'
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $reportPath = Join-Path $reportDir 'history-report.html'

        $html = @'
<!DOCTYPE html>
<html><body>
  <img src="data:image/png;base64,AA==" alt="Before">
  <img src='data:image/gif;base64,AA==' alt='After'>
</body></html>
'@
        Set-Content -LiteralPath $reportPath -Value $html -Encoding utf8

        $outputDir = Join-Path $TestDrive 'previews'
        $indexPath = Join-Path $TestDrive 'image-index.json'
        $result = & $script:scriptPath -ReportPath $reportPath -OutputDir $outputDir -IndexPath $indexPath

        $result.schema | Should -Be 'pr-vi-history-image-index@v1'
        $result.sourceImageCount | Should -Be 2
        $result.exportedImageCount | Should -Be 2
        $result.images.Count | Should -Be 2
        $result.images[0].fileName | Should -Be 'history-image-000.png'
        $result.images[1].fileName | Should -Be 'history-image-001.gif'
        $result.images[0].status | Should -Be 'saved'
        $result.images[1].status | Should -Be 'saved'

        Test-Path -LiteralPath (Join-Path $outputDir 'history-image-000.png') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $outputDir 'history-image-001.gif') | Should -BeTrue
        Test-Path -LiteralPath $indexPath | Should -BeTrue

        $indexJson = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 8
        $indexJson.schema | Should -Be 'pr-vi-history-image-index@v1'
        $indexJson.exportedImageCount | Should -Be 2
    }

    It 'copies local image sources and marks missing sources clearly' {
        $reportDir = Join-Path $TestDrive 'history-local'
        $assetsDir = Join-Path $reportDir 'assets'
        New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $assetsDir 'before.png'), @(0xCA, 0xFE, 0xBA, 0xBE))

        $reportPath = Join-Path $reportDir 'history-report.html'
        $html = @'
<!DOCTYPE html>
<html><body>
  <img src="assets/before.png" alt="Before">
  <img src="assets/missing.png" alt="Missing">
</body></html>
'@
        Set-Content -LiteralPath $reportPath -Value $html -Encoding utf8

        $outputDir = Join-Path $TestDrive 'previews-local'
        $result = & $script:scriptPath -ReportPath $reportPath -OutputDir $outputDir

        $result.sourceImageCount | Should -Be 2
        $result.exportedImageCount | Should -Be 1
        $result.images[0].status | Should -Be 'saved'
        $result.images[0].sourceType | Should -Be 'file'
        $result.images[1].status | Should -Be 'missing-source'
        $result.images[1].error | Should -Match 'Image source not found'

        Test-Path -LiteralPath (Join-Path $outputDir 'history-image-000.png') | Should -BeTrue
    }

    It 'uses stable file names across repeated runs' {
        $reportDir = Join-Path $TestDrive 'history-repeat'
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $reportPath = Join-Path $reportDir 'history-report.html'

        $html = @'
<!DOCTYPE html>
<html><body>
  <img src="data:image/png;base64,AA==" alt="Only">
</body></html>
'@
        Set-Content -LiteralPath $reportPath -Value $html -Encoding utf8

        $outputDir = Join-Path $TestDrive 'previews-repeat'
        $first = & $script:scriptPath -ReportPath $reportPath -OutputDir $outputDir
        $second = & $script:scriptPath -ReportPath $reportPath -OutputDir $outputDir

        $first.images[0].fileName | Should -Be 'history-image-000.png'
        $second.images[0].fileName | Should -Be 'history-image-000.png'
        $second.exportedImageCount | Should -Be 1

        $imageFiles = @(Get-ChildItem -LiteralPath $outputDir -File -Filter 'history-image-*')
        $imageFiles.Count | Should -Be 1
    }
}
