Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Assert-ReleaseCliScenarioMatrix.ps1' -Tag 'Unit' {
  It 'passes for the expected truth table' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Assert-ReleaseCliScenarioMatrix.ps1'

    $csvPath = Join-Path $TestDrive 'matrix.csv'
    @(
      'scenarioId,fixture,diff,nonInteractive,headless,exitCode,gateOutcome,failureClass',
      's1,bd-cosmetic,False,False,False,0,pass,none',
      's2,bd-cosmetic,True,False,True,0,pass,none',
      's3,bd-cosmetic,False,True,False,1,fail,preflight',
      's4,bd-cosmetic,True,True,False,1,fail,preflight'
    ) | Set-Content -LiteralPath $csvPath -Encoding utf8

    $resultJson = & $scriptPath -CsvPath $csvPath -ExpectedFixtures 1
    $result = $resultJson | ConvertFrom-Json -Depth 6
    $result.status | Should -Be 'pass'
    $result.violations.Count | Should -Be 0
  }

  It 'fails when nonInteractive without headless exits zero' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Assert-ReleaseCliScenarioMatrix.ps1'

    $csvPath = Join-Path $TestDrive 'matrix.csv'
    @(
      'scenarioId,fixture,diff,nonInteractive,headless,exitCode,gateOutcome,failureClass',
      's1,bd-cosmetic,False,True,False,0,pass,none'
    ) | Set-Content -LiteralPath $csvPath -Encoding utf8

    { & $scriptPath -CsvPath $csvPath -ExpectedFixtures 1 } | Should -Throw '*violations*'
  }
}
