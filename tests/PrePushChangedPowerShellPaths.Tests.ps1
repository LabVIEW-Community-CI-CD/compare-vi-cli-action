#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pre-push changed PowerShell path discovery' -Tag 'Unit' {
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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Get-ChangedPowerShellPaths')
  }

  It 'stops at the first valid diff range even when that range is empty' {
    $repoRoot = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    $script:GitCalls = New-Object System.Collections.Generic.List[string]

    function git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $range = $Args[5]
      $script:GitCalls.Add($range) | Out-Null
      $global:LASTEXITCODE = 0
      return @()
    }

    $paths = @(Get-ChangedPowerShellPaths -repoRoot $repoRoot)

    $paths.Count | Should -Be 0
    $script:GitCalls | Should -Be @('upstream/develop...HEAD')

    Remove-Item Function:\git -ErrorAction SilentlyContinue
  }

  It 'falls back to the next range only when the preferred range is invalid' {
    $repoRoot = Join-Path $TestDrive 'repo-fallback'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    $changedFile = Join-Path $repoRoot 'tools' 'Changed.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $changedFile) -Force | Out-Null
    Set-Content -LiteralPath $changedFile -Value 'Write-Output ''ok''' -Encoding utf8
    $script:GitCalls = New-Object System.Collections.Generic.List[string]

    function git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $range = $Args[5]
      $script:GitCalls.Add($range) | Out-Null
      if ($range -eq 'upstream/develop...HEAD') {
        $global:LASTEXITCODE = 128
        return @()
      }

      $global:LASTEXITCODE = 0
      return @('tools/Changed.ps1')
    }

    $paths = @(Get-ChangedPowerShellPaths -repoRoot $repoRoot)

    $paths | Should -Be @($changedFile)
    $script:GitCalls | Should -Be @('upstream/develop...HEAD', 'origin/develop...HEAD')

    Remove-Item Function:\git -ErrorAction SilentlyContinue
  }
}
