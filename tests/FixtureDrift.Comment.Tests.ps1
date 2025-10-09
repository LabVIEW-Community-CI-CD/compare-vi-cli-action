Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-FixtureDriftComment' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    Import-Module (Join-Path $repoRoot 'scripts' 'Build-FixtureDriftComment.ps1') -Force
  }

  It 'embeds sanitized HTML report inline' {
    $reportPath = Join-Path $TestDrive 'report.html'
    Set-Content -LiteralPath $reportPath -Value "<html><body><h1>Title & < > ' `"</h1></body></html>" -Encoding utf8

    $result = Get-FixtureDriftComment -Marker '<!-- marker -->' -Status 'drift' -ExitCode '1' -RunUrl 'https://example/run' -ArtifactNames @('fixture-drift') -ArtifactPaths @('results/fixture-drift/compare-report.html') -ReportPath $reportPath
    $result | Should -Match '<details><summary>Fixture Drift HTML report \(inline preview\)</summary>'
    $result | Should -Match '&amp;'
    $result | Should -Match '&lt;'
    $result | Should -Match '&quot;'
    $result | Should -Match '&#39;'
    $result | Should -Not -Match '<html>'
  }

  It 'truncates large HTML' {
    $reportPath = Join-Path $TestDrive 'report-large.html'
    $html = '<p>' + ('A' * 25000) + '</p>'
    Set-Content -LiteralPath $reportPath -Value $html -Encoding utf8

    $result = Get-FixtureDriftComment -Marker '<!-- marker -->' -Status 'drift' -ExitCode '1' -RunUrl 'https://example/run' -ReportPath $reportPath
    $result | Should -Match '\.\.\. \(truncated\)'
  }
}
