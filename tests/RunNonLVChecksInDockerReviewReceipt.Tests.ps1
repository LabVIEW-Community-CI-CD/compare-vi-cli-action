#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Docker review-loop receipt host RAM budget projection' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunNonLVChecksScriptPath = Join-Path $repoRoot 'tools' 'Run-NonLVChecksInDocker.ps1'

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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Get-RepoRelativePath')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Read-JsonHashtable')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Write-DockerParityReviewLoopReceipt')
  }

  BeforeEach {
    function global:Get-GitReviewLoopMetadata {
      param([string]$RepoRoot)
      return @{
        headSha = 'abc123'
        branch = 'issue/origin-1400-host-ram-aware-parallel-budgeting'
        upstreamDevelopMergeBase = 'def456'
        dirtyTracked = $false
      }
    }
  }

  AfterEach {
    Remove-Item Function:\global:Get-GitReviewLoopMetadata -ErrorAction SilentlyContinue
  }

  It 'includes the NI Linux host RAM budget artifact in the receipt and recommended review order' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $niRoot = Join-Path $repoRoot 'tests/results/docker-tools-parity/ni-linux-review-suite'
    $reqRoot = Join-Path $repoRoot 'tests/results/docker-tools-parity/requirements-verification'
    New-Item -ItemType Directory -Path $niRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $reqRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'tests/results/_agent/verification') -Force | Out-Null

    '{}' | Set-Content -LiteralPath (Join-Path $niRoot 'review-suite-summary.json') -Encoding utf8
    '<html></html>' | Set-Content -LiteralPath (Join-Path $niRoot 'review-suite-summary.html') -Encoding utf8
    @{
      artifacts = @{
        historyReportMarkdownPath = 'vi-history-report/results/history-report.md'
        historyReportHtmlPath = 'vi-history-report/results/history-report.html'
        historySummaryPath = 'vi-history-report/results/history-summary.json'
        historyInspectionHtmlPath = 'vi-history-report/results/history-suite-inspection.html'
        historyInspectionJsonPath = 'vi-history-report/results/history-suite-inspection.json'
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $niRoot 'vi-history-review-loop-receipt.json') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $niRoot 'host-ram-budget.json') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $reqRoot 'verification-summary.json') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $reqRoot 'trace-matrix.json') -Encoding utf8
    '<html></html>' | Set-Content -LiteralPath (Join-Path $reqRoot 'trace-matrix.html') -Encoding utf8
    '{}' | Set-Content -LiteralPath (Join-Path $repoRoot 'tests/results/_agent/verification/docker-review-loop-summary.json') -Encoding utf8

    $receiptPath = Join-Path $repoRoot 'tests/results/docker-tools-parity/review-loop-receipt.json'
    Write-DockerParityReviewLoopReceipt `
      -RepoRoot $repoRoot `
      -ReceiptPath $receiptPath `
      -Checks @{} `
      -RunRecord @{ status = 'passed'; exitCode = 0 } `
      -NILinuxResultsRoot 'tests/results/docker-tools-parity/ni-linux-review-suite' `
      -RequirementsResultsRoot 'tests/results/docker-tools-parity/requirements-verification'

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.artifacts.hostRamBudgetPath | Should -Be 'tests/results/docker-tools-parity/ni-linux-review-suite/host-ram-budget.json'
    @($receipt.recommendedReviewOrder) | Should -Contain 'tests/results/docker-tools-parity/ni-linux-review-suite/host-ram-budget.json'
  }
}
