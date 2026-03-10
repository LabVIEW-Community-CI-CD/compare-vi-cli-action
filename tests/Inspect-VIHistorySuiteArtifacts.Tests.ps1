Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Inspect-VIHistorySuiteArtifacts.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Inspect-VIHistorySuiteArtifacts.ps1'
  }

  It 'builds a consolidated inspection HTML with resolved host image paths' {
    $resultsDir = Join-Path $TestDrive 'history-results'
    $modeDir = Join-Path $resultsDir 'default'
    $assetDir = Join-Path $modeDir 'pair-001-report_files'
    New-Item -ItemType Directory -Path $assetDir -Force | Out-Null

    $historyReportPath = Join-Path $resultsDir 'history-report.html'
    $historySummaryPath = Join-Path $resultsDir 'history-summary.json'
    $suiteManifestPath = Join-Path $resultsDir 'suite-manifest.json'
    $modeManifestPath = Join-Path $modeDir 'manifest.json'
    $pairReportPath = Join-Path $modeDir 'pair-001-report.html'

    @'
<html><body>
  <table>
    <tr>
      <td><a href="./default/pair-001-report.html">pair-001-report.html</a></td>
      <td>
        <img class="preview-image" src="./default/pair-001-report_files/fp_1.png" />
        <img class="preview-image" src="./default/pair-001-report_files/fp_2.png" />
      </td>
    </tr>
  </table>
</body></html>
'@ |
      Set-Content -LiteralPath $historyReportPath -Encoding utf8
    @'
{
  "schema": "comparevi-tools/history-facade@v1",
  "reports": {
    "htmlPath": "/opt/comparevi/vi-history/results/history-report.html",
    "markdownPath": "/opt/comparevi/vi-history/results/history-report.md"
  }
}
'@ | Set-Content -LiteralPath $historySummaryPath -Encoding utf8
    @'
{
  "schema": "vi-compare/history-suite@v1",
  "modes": [
    {
      "name": "default",
      "slug": "default"
    }
  ]
}
'@ | Set-Content -LiteralPath $suiteManifestPath -Encoding utf8
    @'
{
  "schema": "vi-compare/history@v1",
  "comparisons": [
    {
      "index": 1,
      "outName": "pair-001",
      "result": {
        "diff": true,
        "status": "completed",
        "reportPath": "/opt/comparevi/vi-history/results/default/pair-001-report.html"
      }
    }
  ]
}
'@ | Set-Content -LiteralPath $modeManifestPath -Encoding utf8
    @'
<html><body>
  <img class="difference-image" src="pair-001-report_files/fp_1.png" />
  <img class="difference-image" src="pair-001-report_files/fp_2.png" />
</body></html>
'@ | Set-Content -LiteralPath $pairReportPath -Encoding utf8
    [System.IO.File]::WriteAllBytes((Join-Path $assetDir 'fp_1.png'), @(0x01, 0x02, 0x03))
    [System.IO.File]::WriteAllBytes((Join-Path $assetDir 'fp_2.png'), @(0x04, 0x05, 0x06))

    $outputJsonPath = Join-Path $resultsDir 'history-suite-inspection.json'
    $outputHtmlPath = Join-Path $resultsDir 'history-suite-inspection.html'
    $result = & $script:scriptPath `
      -ResultsDir $resultsDir `
      -HistoryReportPath $historyReportPath `
      -HistorySummaryPath $historySummaryPath `
      -OutputJsonPath $outputJsonPath `
      -OutputHtmlPath $outputHtmlPath `
      -GitHubOutputPath '' `
      -GitHubStepSummaryPath ''

    $result.overallStatus | Should -Be 'ok'
    $result.summary.comparisons | Should -Be 1
    $result.summary.missingImages | Should -Be 0
    $result.pairs.Count | Should -Be 1
    $result.pairs[0].inspectionStatus | Should -Be 'ok'
    $result.pairs[0].imageCount | Should -Be 2

    Test-Path -LiteralPath $outputJsonPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $outputHtmlPath -PathType Leaf | Should -BeTrue
    (Get-Content -LiteralPath $outputHtmlPath -Raw) | Should -Match 'default/pair-001-report_files/fp_1\.png'
    (Get-Content -LiteralPath $outputHtmlPath -Raw) | Should -Match 'VI history suite inspection'
  }

  It 'fails when a pair report references a missing host image' {
    $resultsDir = Join-Path $TestDrive 'history-results-missing'
    $modeDir = Join-Path $resultsDir 'default'
    $assetDir = Join-Path $modeDir 'pair-001-report_files'
    New-Item -ItemType Directory -Path $assetDir -Force | Out-Null

    $historyReportPath = Join-Path $resultsDir 'history-report.html'
    $historySummaryPath = Join-Path $resultsDir 'history-summary.json'
    $suiteManifestPath = Join-Path $resultsDir 'suite-manifest.json'
    $modeManifestPath = Join-Path $modeDir 'manifest.json'
    $pairReportPath = Join-Path $modeDir 'pair-001-report.html'

    @'
<html><body>
  <a href="./default/pair-001-report.html">pair-001-report.html</a>
  <img class="preview-image" src="./default/pair-001-report_files/fp_1.png" />
</body></html>
'@ |
      Set-Content -LiteralPath $historyReportPath -Encoding utf8
    '{"schema":"comparevi-tools/history-facade@v1","reports":{"htmlPath":"/opt/comparevi/vi-history/results/history-report.html"}}' |
      Set-Content -LiteralPath $historySummaryPath -Encoding utf8
    '{"schema":"vi-compare/history-suite@v1","modes":[{"name":"default","slug":"default"}]}' |
      Set-Content -LiteralPath $suiteManifestPath -Encoding utf8
    '{"schema":"vi-compare/history@v1","comparisons":[{"index":1,"outName":"pair-001","result":{"status":"completed","diff":true,"reportPath":"/opt/comparevi/vi-history/results/default/pair-001-report.html"}}]}' |
      Set-Content -LiteralPath $modeManifestPath -Encoding utf8
    '<html><body><img class="difference-image" src="pair-001-report_files/fp_1.png" /></body></html>' |
      Set-Content -LiteralPath $pairReportPath -Encoding utf8

    {
      & $script:scriptPath `
        -ResultsDir $resultsDir `
        -HistoryReportPath $historyReportPath `
        -HistorySummaryPath $historySummaryPath `
        -OutputJsonPath (Join-Path $resultsDir 'history-suite-inspection.json') `
        -OutputHtmlPath (Join-Path $resultsDir 'history-suite-inspection.html') `
        -GitHubOutputPath '' `
        -GitHubStepSummaryPath ''
    } | Should -Throw '*missingImages=1*'
  }
}
