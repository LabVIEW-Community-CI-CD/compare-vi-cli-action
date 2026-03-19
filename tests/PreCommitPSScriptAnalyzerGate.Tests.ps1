#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pre-commit PSScriptAnalyzer gate' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PreCommitScriptPath = Join-Path $repoRoot 'tools' 'hooks' 'scripts' 'pre-commit.ps1'

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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PreCommitScriptPath -FunctionName 'Invoke-PSScriptAnalyzerGate')
  }

  It 'fails when PSScriptAnalyzer is unavailable and the gate was not explicitly skipped' {
    $script:SkipPSScriptAnalyzer = $false
    $env:PRECOMMIT_SKIP_PSSCRIPTANALYZER = ''

    function Get-Module { param([switch]$ListAvailable, [string]$Name) return $null }

    { Invoke-PSScriptAnalyzerGate -Paths @('example.ps1') } |
      Should -Throw 'PSScriptAnalyzer not installed; install the module or rerun with -SkipPSScriptAnalyzer (or PRECOMMIT_SKIP_PSSCRIPTANALYZER=1).'

    Remove-Item Function:\Get-Module -ErrorAction SilentlyContinue
  }

  It 'still allows an explicit skip request to bypass the analyzer gate' {
    $script:SkipPSScriptAnalyzer = $false
    $env:PRECOMMIT_SKIP_PSSCRIPTANALYZER = 'true'

    function Get-Module { param([switch]$ListAvailable, [string]$Name) return $null }

    { Invoke-PSScriptAnalyzerGate -Paths @('example.ps1') } | Should -Not -Throw

    Remove-Item Function:\Get-Module -ErrorAction SilentlyContinue
    $env:PRECOMMIT_SKIP_PSSCRIPTANALYZER = ''
  }
}
