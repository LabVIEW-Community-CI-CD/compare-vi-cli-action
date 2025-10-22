Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-FixtureDriftComment' -Tag 'Unit' {
  BeforeAll {
    try {
      $scriptPath = $PSCommandPath
      if ([string]::IsNullOrWhiteSpace($scriptPath) -and $null -ne $MyInvocation?.MyCommand?.Path) {
        $scriptPath = $MyInvocation.MyCommand.Path
      }
      if ([string]::IsNullOrWhiteSpace($scriptPath) -and $PSScriptRoot) {
        $scriptPath = Join-Path $PSScriptRoot 'FixtureDrift.Comment.Tests.ps1'
      }
      if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw [System.InvalidOperationException]::new('Unable to resolve script path for FixtureDrift.Comment tests.')
      }

      $testDir = Split-Path -Parent $scriptPath
      $repoRoot = Resolve-Path (Join-Path $testDir '..') -ErrorAction Stop
      $modulePath = Join-Path $repoRoot 'scripts' 'Build-FixtureDriftComment.ps1'

      if (-not (Test-Path -LiteralPath $modulePath)) {
        throw [System.IO.FileNotFoundException]::new("Fixture drift helper not found", $modulePath)
      }

      Write-Host "[FixtureDrift] scriptPath=$scriptPath" -ForegroundColor Cyan
      Write-Host "[FixtureDrift] modulePath=$modulePath" -ForegroundColor Cyan

      . "$modulePath"
    } catch {
      $err = $_
      $msg = "Fixture drift test setup failed: {0}" -f ($err.Exception.Message ?? $err.ToString())
      throw [System.Exception]::new($msg, $err.Exception)
    }
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
