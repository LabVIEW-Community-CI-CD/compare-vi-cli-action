#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pre-push dependency audit observation' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PrePushScriptPath = Join-Path $repoRoot 'tools' 'PrePush-Checks.ps1'

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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Invoke-DependencyAuditObservation')
  }

  BeforeEach {
    $script:NodeCalls = @()
    $script:MockAuditResult = 'pass'
    $script:MockNodeExitCode = 0

    function global:node {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

      $script:NodeCalls += ,@($Args)
      $repoRoot = (Get-Location).Path
      $reportPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'security' 'dependency-audit-report.json'
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
      @{
        schema = 'priority/dependency-audit@v1'
        schemaVersion = '1.0.0'
        generatedAt = '2026-03-20T00:00:00Z'
        mode = 'observe'
        result = $script:MockAuditResult
        command = @{
          command = 'node'
          args = @('npm-cli.js', 'audit', '--json')
          sanitizedNpmEnv = $true
          rawOutputPath = 'tests/results/_agent/security/npm-audit.json'
        }
        execution = @{
          npmExitCode = 0
          stderr = $null
          jsonParsed = $true
        }
        packageState = @{
          nodeVersion = 'v24.13.1'
          packageJson = @{
            path = 'package.json'
            exists = $true
            sha256 = ('a' * 64)
            packageName = 'compare-vi-cli-action'
            packageVersion = '0.6.3'
          }
          packageLock = @{
            path = 'package-lock.json'
            exists = $true
            sha256 = ('b' * 64)
            lockfileVersion = 3
          }
          fingerprintSha256 = ('c' * 64)
        }
        thresholds = @{
          total = 0
          critical = 0
          high = 0
          moderate = 0
        }
        summary = @{
          total = 0
          critical = 0
          high = 0
          moderate = 0
          low = 0
          info = 0
          dependencyCounts = @{
            prod = 1
            dev = 1
            optional = 0
            peer = 0
            peerOptional = 0
            total = 2
          }
        }
        packages = @()
        breaches = @()
        errors = @()
      } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
      $global:LASTEXITCODE = $script:MockNodeExitCode
    }
  }

  AfterEach {
    Remove-Item Function:\global:node -ErrorAction SilentlyContinue
  }

  It 'invokes the sanitized npm wrapper and accepts a pass report' {
    $repoRoot = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot 'tools' 'npm') | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'tools' 'npm' 'run-script.mjs') -Value '' -Encoding utf8

    { Invoke-DependencyAuditObservation -repoRoot $repoRoot } | Should -Not -Throw
    $script:NodeCalls.Count | Should -Be 1
    @($script:NodeCalls[0]) | Should -Be @((Join-Path $repoRoot 'tools' 'npm' 'run-script.mjs'), 'priority:security:audit')
  }

  It 'keeps warn reports non-blocking in observe mode' {
    $script:MockAuditResult = 'warn'
    $repoRoot = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot 'tools' 'npm') | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'tools' 'npm' 'run-script.mjs') -Value '' -Encoding utf8

    { Invoke-DependencyAuditObservation -repoRoot $repoRoot } | Should -Not -Throw
  }

  It 'throws when the observation command itself exits non-zero unexpectedly' {
    $script:MockNodeExitCode = 1
    $repoRoot = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot 'tools' 'npm') | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'tools' 'npm' 'run-script.mjs') -Value '' -Encoding utf8

    { Invoke-DependencyAuditObservation -repoRoot $repoRoot } |
      Should -Throw 'dependency audit observation failed unexpectedly (exit=1).'
  }
}
