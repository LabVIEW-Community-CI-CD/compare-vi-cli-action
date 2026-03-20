#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'NI Linux review-suite flag certification artifacts' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ReviewSuiteScriptPath = Join-Path $repoRoot 'tools' 'Invoke-NILinuxReviewSuite.ps1'

    if (-not (Test-Path -LiteralPath $script:ReviewSuiteScriptPath -PathType Leaf)) {
      throw "Invoke-NILinuxReviewSuite.ps1 not found at $script:ReviewSuiteScriptPath"
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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:ReviewSuiteScriptPath -FunctionName 'Get-RelativeArtifactPath')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:ReviewSuiteScriptPath -FunctionName 'Write-FlagCombinationCertificationArtifacts')
  }

  It 'writes explicit certification artifacts for the broad flag-combination sweep' {
    $resultsRoot = Join-Path $TestDrive 'ni-linux-review-suite'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resultsRoot 'flag-combinations' 'baseline') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resultsRoot 'flag-combinations' 'noattr') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resultsRoot 'vi-history-report') -Force | Out-Null

    $scenarioResults = @(
      [pscustomobject]@{
        kind = 'flag-combination'
        name = 'baseline'
        requestedFlagsLabel = '(none)'
        requestedFlags = @()
        flagsUsed = @('-Headless')
        executionMode = 'docker-run'
        resultClass = 'success-diff'
        gateOutcome = 'pass'
        reportPath = (Join-Path $resultsRoot 'flag-combinations' 'baseline' 'compare-report.html')
        capturePath = (Join-Path $resultsRoot 'flag-combinations' 'baseline' 'ni-linux-container-capture.json')
        runtimeSnapshotPath = (Join-Path $resultsRoot 'flag-combinations' 'baseline' 'runtime-determinism.json')
      },
      [pscustomobject]@{
        kind = 'flag-combination'
        name = 'noattr'
        requestedFlagsLabel = '-noattr'
        requestedFlags = @('-noattr')
        flagsUsed = @('-Headless', '-noattr')
        executionMode = 'docker-run'
        resultClass = 'success-diff'
        gateOutcome = 'pass'
        reportPath = (Join-Path $resultsRoot 'flag-combinations' 'noattr' 'compare-report.html')
        capturePath = (Join-Path $resultsRoot 'flag-combinations' 'noattr' 'ni-linux-container-capture.json')
        runtimeSnapshotPath = (Join-Path $resultsRoot 'flag-combinations' 'noattr' 'runtime-determinism.json')
      },
      [pscustomobject]@{
        kind = 'vi-history-report'
        name = 'vi-history-report'
        requestedFlagsLabel = 'vi-history-suite'
        requestedFlags = @('vi-history-suite')
        flagsUsed = @('-Headless')
        executionMode = 'docker-run'
        resultClass = 'success-diff'
        gateOutcome = 'pass'
        reportPath = (Join-Path $resultsRoot 'vi-history-report' 'history-report.html')
        capturePath = (Join-Path $resultsRoot 'vi-history-report' 'ni-linux-container-capture.json')
        runtimeSnapshotPath = (Join-Path $resultsRoot 'vi-history-report' 'runtime-determinism.json')
      }
    )

    $artifacts = Write-FlagCombinationCertificationArtifacts `
      -ResultsRoot $resultsRoot `
      -Image 'nationalinstruments/labview:2026q1-linux' `
      -ScenarioResults $scenarioResults `
      -ParallelBudget ([pscustomobject]@{
        requestedParallelism = 0
        actualParallelism = 2
        decisionSource = 'host-ram-budget'
      })

    Test-Path -LiteralPath $artifacts.jsonPath | Should -BeTrue
    Test-Path -LiteralPath $artifacts.markdownPath | Should -BeTrue
    Test-Path -LiteralPath $artifacts.htmlPath | Should -BeTrue

    $report = Get-Content -LiteralPath $artifacts.jsonPath -Raw | ConvertFrom-Json -Depth 12
    $report.schema | Should -Be 'ni-linux-flag-combination-certification@v1'
    $report.laneClass | Should -Be 'certification'
    $report.blocking | Should -BeFalse
    @($report.planeApplicability) | Should -Be @('linux-proof')
    @($report.futureParityPlanes) | Should -Contain 'windows-mirror-proof'
    @($report.futureParityPlanes) | Should -Contain 'host-32bit-shadow'
    $report.summary.totalScenarios | Should -Be 2
    $report.summary.passingScenarios | Should -Be 2
    $report.summary.failingScenarios | Should -Be 0
    $report.parallelBudget.actualParallelism | Should -Be 2
    $report.parallelBudget.decisionSource | Should -Be 'host-ram-budget'
    @($report.scenarios | ForEach-Object { $_.name }) | Should -Be @('baseline', 'noattr')

    $markdown = Get-Content -LiteralPath $artifacts.markdownPath -Raw
    $markdown | Should -Match 'NI Linux flag-combination certification'
    $markdown | Should -Match 'Parallelism'
    $markdown | Should -Match 'baseline'
    $markdown | Should -Match 'noattr'

    $html = Get-Content -LiteralPath $artifacts.htmlPath -Raw
    $html | Should -Match 'flag-combination certification'
    $html | Should -Match 'windows-mirror-proof'
  }
}
