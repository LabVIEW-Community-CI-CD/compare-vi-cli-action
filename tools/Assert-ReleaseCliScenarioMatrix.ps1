#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$CsvPath = 'tests/results/_agent/release-v1.0.1/scenario-matrix/scenario-results.csv',
  [int]$ExpectedFixtures = 0,
  [switch]$AppendStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
  throw "Scenario matrix CSV not found: $CsvPath"
}

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -lt 1) {
  throw "Scenario matrix CSV is empty: $CsvPath"
}

$fixtures = @($rows | Select-Object -ExpandProperty fixture -Unique | Sort-Object)
if ($ExpectedFixtures -gt 0 -and $fixtures.Count -ne $ExpectedFixtures) {
  throw "Expected $ExpectedFixtures fixtures but found $($fixtures.Count) in $CsvPath"
}

$combos = @($rows | Group-Object diff, nonInteractive, headless | Sort-Object Name)
$violations = New-Object System.Collections.Generic.List[string]

foreach ($combo in $combos) {
  $sample = $combo.Group[0]
  $diff = [System.Convert]::ToBoolean($sample.diff)
  $nonInteractive = [System.Convert]::ToBoolean($sample.nonInteractive)
  $headless = [System.Convert]::ToBoolean($sample.headless)

  $expectFail = ($nonInteractive -and -not $headless)
  $expectedExit = if ($expectFail) { 'nonzero' } else { 'zero' }
  $expectedGate = if ($expectFail) { 'fail' } else { 'pass' }

  foreach ($row in $combo.Group) {
    $exitCode = 0
    [void][int]::TryParse([string]$row.exitCode, [ref]$exitCode)
    $gate = [string]$row.gateOutcome
    $failureClass = [string]$row.failureClass

    if ($expectFail) {
      if ($exitCode -eq 0) {
        $violations.Add("$($row.scenarioId): expected nonzero exit for nonInteractive=true && headless=false") | Out-Null
      }
      if ($gate -ne 'fail') {
        $violations.Add("$($row.scenarioId): expected gateOutcome=fail, got '$gate'") | Out-Null
      }
      if ($failureClass -ne 'preflight') {
        $violations.Add("$($row.scenarioId): expected failureClass=preflight, got '$failureClass'") | Out-Null
      }
    }
    else {
      if ($exitCode -ne 0) {
        $violations.Add("$($row.scenarioId): expected exitCode=0, got $exitCode") | Out-Null
      }
      if ($gate -ne 'pass') {
        $violations.Add("$($row.scenarioId): expected gateOutcome=pass, got '$gate'") | Out-Null
      }
      if (-not [string]::IsNullOrWhiteSpace($failureClass) -and $failureClass -ne 'none') {
        $violations.Add("$($row.scenarioId): expected failureClass empty/none, got '$failureClass'") | Out-Null
      }
    }
  }

  Write-Host ("combo diff={0} nonInteractive={1} headless={2}: scenarios={3} expected={4}/{5}" -f $diff, $nonInteractive, $headless, $combo.Count, $expectedExit, $expectedGate)
}

$summary = [ordered]@{
  csvPath = $CsvPath
  totalScenarios = $rows.Count
  fixtureCount = $fixtures.Count
  fixtures = $fixtures
  comboCount = $combos.Count
  violations = @($violations)
  status = if ($violations.Count -eq 0) { 'pass' } else { 'fail' }
}

if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  $lines = @(
    '### Release CLI scenario matrix assertion',
    ('- CSV: `{0}`' -f $CsvPath),
    ('- Total scenarios: `{0}`' -f $rows.Count),
    ('- Fixtures: `{0}`' -f ($fixtures -join ', ')),
    ('- Status: `{0}`' -f $summary.status)
  )
  if ($violations.Count -gt 0) {
    $lines += '- Violations:'
    $violations | ForEach-Object { $lines += ('  - {0}' -f $_) }
  }
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($lines -join [Environment]::NewLine)
}

$summary | ConvertTo-Json -Depth 6

if ($violations.Count -gt 0) {
  throw "Scenario matrix assertions failed ($($violations.Count) violations)."
}
