#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'NI Linux review-suite RAM budget planning' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ReviewSuiteScriptPath = Join-Path $repoRoot 'tools' 'Invoke-NILinuxReviewSuite.ps1'

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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:ReviewSuiteScriptPath -FunctionName 'Resolve-AbsolutePath')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:ReviewSuiteScriptPath -FunctionName 'Get-DefaultHostRamBudgetPath')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:ReviewSuiteScriptPath -FunctionName 'Resolve-FlagScenarioParallelBudget')
  }

  BeforeEach {
    $script:NodeCalls = @()
  }

  AfterEach {
    Remove-Item Function:\global:node -ErrorAction SilentlyContinue
  }

  It 'defaults the host RAM budget path under the results root' {
    $resultsRoot = Join-Path $TestDrive 'results'
    $resolved = Get-DefaultHostRamBudgetPath -ResultsRoot $resultsRoot

    $resolved | Should -Be (Join-Path $resultsRoot 'host-ram-budget.json')
  }

  It 'uses the explicit parallelism override without invoking the node helper' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    function global:node {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      throw 'node should not be called for explicit parallelism overrides'
    }

    $plan = Resolve-FlagScenarioParallelBudget -RepoRoot $repoRoot -ResultsRoot $resultsRoot -RequestedParallelism 3 -HostRamBudgetPath '' -ReuseContainerName ''

    $plan.requestedParallelism | Should -Be 3
    $plan.recommendedParallelism | Should -Be 3
    $plan.actualParallelism | Should -Be 3
    $plan.decisionSource | Should -Be 'explicit-override'
  }

  It 'hydrates the budget from the node helper when no override is provided' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results'
    $helperPath = Join-Path $repoRoot 'tools' 'priority'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $helperPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $helperPath 'host-ram-budget.mjs') -Value '' -Encoding utf8

    function global:node {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

      $script:NodeCalls += ,@($Args)
      $outputIndex = [Array]::IndexOf($Args, '--output')
      if ($outputIndex -lt 0) {
        throw 'Missing --output for host-ram-budget helper'
      }
      $outputPath = $Args[$outputIndex + 1]
      New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
      @{
        schema = 'priority/host-ram-budget@v1'
        generatedAt = '2026-03-20T05:20:00Z'
        host = @{
          platform = 'win32'
          arch = 'x64'
          detectionSource = 'node-os'
          totalBytes = 17179869184
          freeBytes = 10737418240
          cpuParallelism = 12
        }
        policy = @{
          minimumParallelism = 1
          systemReserveBytes = 4294967296
          freeReserveBytes = 1717986918
          usableByTotalBytes = 12884901888
          usableByFreeBytes = 9019431322
          effectiveUsableBytes = 9019431322
        }
        profiles = @()
        selectedProfile = @{
          id = 'ni-linux-flag-combination'
          laneClass = 'ram-bound'
          perWorkerBytes = 3221225472
          maxParallelism = 3
          memoryBoundCeiling = 2
          cpuBoundCeiling = 12
          recommendedParallelism = 2
          floorApplied = $false
          degradedByPressure = $true
          reasons = @('free-memory-pressure', 'memory-cap')
        }
      } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputPath -Encoding utf8
      $global:LASTEXITCODE = 0
    }

    $plan = Resolve-FlagScenarioParallelBudget -RepoRoot $repoRoot -ResultsRoot $resultsRoot -RequestedParallelism 0 -HostRamBudgetPath '' -ReuseContainerName ''

    $script:NodeCalls.Count | Should -Be 1
    $plan.recommendedParallelism | Should -Be 2
    $plan.actualParallelism | Should -Be 2
    $plan.decisionSource | Should -Be 'host-ram-budget'
    $plan.reason | Should -Match 'free-memory-pressure'
    Test-Path -LiteralPath $plan.path | Should -BeTrue
  }

  It 'forces serial flag-scenario execution when reusing a warm container' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results'
    $helperPath = Join-Path $repoRoot 'tools' 'priority'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $helperPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $helperPath 'host-ram-budget.mjs') -Value '' -Encoding utf8

    function global:node {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

      $outputIndex = [Array]::IndexOf($Args, '--output')
      if ($outputIndex -lt 0) {
        throw 'Missing --output for host-ram-budget helper'
      }
      $outputPath = $Args[$outputIndex + 1]
      New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
      @{
        schema = 'priority/host-ram-budget@v1'
        generatedAt = '2026-03-20T05:20:00Z'
        host = @{
          platform = 'win32'
          arch = 'x64'
          detectionSource = 'node-os'
          totalBytes = 17179869184
          freeBytes = 10737418240
          cpuParallelism = 12
        }
        policy = @{
          minimumParallelism = 1
          systemReserveBytes = 4294967296
          freeReserveBytes = 1717986918
          usableByTotalBytes = 12884901888
          usableByFreeBytes = 9019431322
          effectiveUsableBytes = 9019431322
        }
        profiles = @()
        selectedProfile = @{
          id = 'ni-linux-flag-combination'
          laneClass = 'ram-bound'
          perWorkerBytes = 3221225472
          maxParallelism = 3
          memoryBoundCeiling = 2
          cpuBoundCeiling = 12
          recommendedParallelism = 2
          floorApplied = $false
          degradedByPressure = $true
          reasons = @('free-memory-pressure', 'memory-cap')
        }
      } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputPath -Encoding utf8
      $global:LASTEXITCODE = 0
    }

    $plan = Resolve-FlagScenarioParallelBudget -RepoRoot $repoRoot -ResultsRoot $resultsRoot -RequestedParallelism 0 -HostRamBudgetPath '' -ReuseContainerName 'warm-stub'

    $plan.recommendedParallelism | Should -Be 2
    $plan.actualParallelism | Should -Be 1
    $plan.decisionSource | Should -Be 'host-ram-budget'
    $plan.reason | Should -Be 'reuse-container-single-runtime'
  }
}
