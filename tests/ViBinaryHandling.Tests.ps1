Describe 'VI Binary Handling Invariants' -Tag 'Unit' {
  It 'passes the standalone invariant contract script' {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'Test-VIBinaryHandlingInvariants.ps1'
    $reportPath = Join-Path $TestDrive 'vi-binary-handling-invariants.json'

    { & $scriptPath -OutputJsonPath $reportPath } | Should -Not -Throw

    Test-Path -LiteralPath $reportPath | Should -BeTrue
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 8
    $report.schema | Should -Be 'comparevi/vi-binary-handling-invariants@v1'
    $report.status | Should -Be 'passed'
    @($report.checks).Count | Should -BeGreaterThan 1
    (@($report.violations).Count) | Should -Be 0
  }
}
