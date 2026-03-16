#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pre-push known-flag scenario report' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PrePushScriptPath = Join-Path $repoRoot 'tools' 'PrePush-Checks.ps1'
    $script:KnownFlagContractPath = Join-Path $repoRoot 'tools' 'policy' 'prepush-known-flag-scenarios.json'

    if (-not (Test-Path -LiteralPath $script:PrePushScriptPath -PathType Leaf)) {
      throw "PrePush-Checks.ps1 not found at $script:PrePushScriptPath"
    }
    if (-not (Test-Path -LiteralPath $script:KnownFlagContractPath -PathType Leaf)) {
      throw "Known-flag scenario contract not found at $script:KnownFlagContractPath"
    }

    function script:Get-ScriptFunctionDefinition {
      param(
        [string]$ScriptPath,
        [string]$FunctionName
      )

      $tokens = $null
      $parseErrors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
      if ($parseErrors.Count -gt 0) {
        throw ("Failed to parse {0}: {1}" -f $ScriptPath, ($parseErrors | ForEach-Object { $_.Message } | Join-String -Separator '; '))
      }

      $functionAst = $ast.Find(
        {
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $FunctionName
        },
        $true
      )
      if ($null -eq $functionAst) {
        throw ("Function {0} not found in {1}" -f $FunctionName, $ScriptPath)
      }

      return $functionAst.Extent.Text
    }

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Write-PrePushKnownFlagScenarioReport')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'ConvertTo-PrePushKnownFlagScenarioResultArray')
    $script:KnownFlagContract = Get-Content -LiteralPath $script:KnownFlagContractPath -Raw | ConvertFrom-Json -Depth 12
    $script:ActiveScenario = @($script:KnownFlagContract.scenarios | Where-Object { $_.isActive -eq $true }) | Select-Object -First 1
    if ($null -eq $script:ActiveScenario) {
      throw 'Active known-flag scenario not found in contract.'
    }
  }

  It 'writes a deterministic report that mirrors the active scenario contract and observed evidence paths' {
    $repoRoot = Join-Path $TestDrive 'non-git-repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'pre-push-ni-image'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $contract = [pscustomobject]@{
      path = $script:KnownFlagContractPath
      scenario = $script:ActiveScenario
      flags = @($script:ActiveScenario.flags)
      reportPath = Join-Path $resultsRoot 'known-flag-scenario-report.json'
    }
    $scenarioResults = @(
      [pscustomobject]@{
        name = 'ni-linux-known-flag-bundle-v1'
        requestedFlags = @('-noattr', '-nofppos', '-nobdcosm')
        flags = @('-noattr', '-nofppos', '-nobdcosm')
        resultClass = 'pass'
        gateOutcome = 'pass'
        capturePath = 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/capture.json'
        reportPath = 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/report.html'
      }
    )

    $reportPath = Write-PrePushKnownFlagScenarioReport `
      -repoRoot $repoRoot `
      -contract $contract `
      -observedOutcome 'pass' `
      -scenarioResults $scenarioResults `
      -failureMessage '' `
      -activeScenarioName 'ni-linux-known-flag-bundle-v1' `
      -activeCapturePath 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/capture.json' `
      -activeReportPath 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/report.html'

    $reportPath | Should -Be $contract.reportPath
    Test-Path -LiteralPath $reportPath | Should -BeTrue

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 16
    $report.schema | Should -Be 'pre-push-known-flag-scenario-report@v1'
    $report.contractPath | Should -Be $script:KnownFlagContractPath
    $report.branch | Should -BeNullOrEmpty
    $report.headSha | Should -BeNullOrEmpty
    $report.scenario.id | Should -Be $script:KnownFlagContract.activeScenarioId
    $report.scenario.image | Should -Be $script:ActiveScenario.image
    $report.scenario.labviewPathEnv | Should -Be $script:ActiveScenario.labviewPathEnv
    $report.scenario.defaultLabviewPath | Should -Be $script:ActiveScenario.defaultLabviewPath
    $report.scenario.requestedFlags | Should -Be @($script:ActiveScenario.flags)
    $report.scenario.expectedGateOutcome | Should -Be $script:ActiveScenario.expectedGateOutcome
    $report.observed.outcome | Should -Be 'pass'
    $report.observed.activeScenarioName | Should -Be 'ni-linux-known-flag-bundle-v1'
    $report.observed.capturePath | Should -Be 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/capture.json'
    $report.observed.reportPath | Should -Be 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/report.html'
    $report.observed.failureMessage | Should -BeNullOrEmpty
    $report.results.Count | Should -Be 1
    $report.results[0].gateOutcome | Should -Be 'pass'
    $report.results[0].capturePath | Should -Be 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/capture.json'
    $report.results[0].reportPath | Should -Be 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/report.html'
  }

  It 'writes failure outcome and evidence paths without depending on a git checkout' {
    $repoRoot = Join-Path $TestDrive 'non-git-failure-repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'pre-push-ni-image'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $contract = [pscustomobject]@{
      path = $script:KnownFlagContractPath
      scenario = $script:ActiveScenario
      flags = @($script:ActiveScenario.flags)
      reportPath = Join-Path $resultsRoot 'known-flag-scenario-report.json'
    }

    $reportPath = Write-PrePushKnownFlagScenarioReport `
      -repoRoot $repoRoot `
      -contract $contract `
      -observedOutcome 'fail' `
      -scenarioResults @() `
      -failureMessage 'known-flag scenario failed' `
      -activeScenarioName 'ni-linux-known-flag-bundle-v1' `
      -activeCapturePath 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/capture.json' `
      -activeReportPath 'tests/results/_agent/pre-push-ni-image/ni-linux-known-flag-bundle-v1/report.html'

    $reportPath | Should -Be $contract.reportPath
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 16
    $report.observed.outcome | Should -Be 'fail'
    $report.observed.failureMessage | Should -Be 'known-flag scenario failed'
    $report.results.Count | Should -Be 0
  }

  It 'normalizes live scenario result collections into plain report records' {
    $scenarioResults = [System.Collections.Generic.List[object]]::new()
    $scenarioResults.Add([pscustomobject]@{
      name = 'baseline'
      requestedFlags = @()
      flags = @('-Headless')
      resultClass = 'diff'
      gateOutcome = 'pass'
      capturePath = 'tests/results/_agent/pre-push-ni-image/baseline/ni-linux-container-capture.json'
      reportPath = 'tests/results/_agent/pre-push-ni-image/baseline/compare-report.html'
    }) | Out-Null
    $scenarioResults.Add([pscustomobject]@{
      name = 'vi-history-report'
      requestedFlags = @('vi-history-suite')
      flags = @('suite-manifest', 'history-report', 'history-summary')
      resultClass = 'diff'
      gateOutcome = 'pass'
      capturePath = 'tests/results/_agent/pre-push-ni-image/vi-history-report/results/ni-linux-container-capture.json'
      reportPath = 'tests/results/_agent/pre-push-ni-image/vi-history-report/results/history-report.html'
    }) | Out-Null

    $normalized = ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $scenarioResults

    $normalized.Count | Should -Be 2
    $normalized[0].name | Should -Be 'baseline'
    $normalized[0].flags | Should -Be @('-Headless')
    $normalized[1].name | Should -Be 'vi-history-report'
    $normalized[1].requestedFlags | Should -Be @('vi-history-suite')
    $normalized[1].reportPath | Should -Be 'tests/results/_agent/pre-push-ni-image/vi-history-report/results/history-report.html'
  }
}
