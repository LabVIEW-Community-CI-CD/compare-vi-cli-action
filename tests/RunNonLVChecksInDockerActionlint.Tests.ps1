#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Docker actionlint surface selection' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunNonLVChecksScriptPath = Join-Path $repoRoot 'tools' 'Run-NonLVChecksInDocker.ps1'

    if (-not (Test-Path -LiteralPath $script:RunNonLVChecksScriptPath -PathType Leaf)) {
      throw "Run-NonLVChecksInDocker.ps1 not found at $script:RunNonLVChecksScriptPath"
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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Get-ActionlintVersionFloor')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Test-ActionlintVersionAtLeast')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Resolve-ActionlintContainerInvocation')
  }

  It 'reads the actionlint version floor from the tools Dockerfile' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    @'
# syntax=docker/dockerfile:1
ARG ACTIONLINT_VERSION=1.7.8
'@ | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    $version = Get-ActionlintVersionFloor -RepoRoot $repoRoot

    $version | Should -Be '1.7.8'
  }

  It 'compares actionlint versions against the required floor' {
    (Test-ActionlintVersionAtLeast -Version '1.7.7' -MinimumVersion '1.7.8') | Should -BeFalse
    (Test-ActionlintVersionAtLeast -Version '1.7.8' -MinimumVersion '1.7.8') | Should -BeTrue
    (Test-ActionlintVersionAtLeast -Version '1.8.0' -MinimumVersion '1.7.8') | Should -BeTrue
    (Test-ActionlintVersionAtLeast -Version '' -MinimumVersion '1.7.8') | Should -BeFalse
  }

  It 'uses the tools image when its actionlint version satisfies the floor' {
    $repoRoot = Join-Path $TestDrive 'repo-tools'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    'ARG ACTIONLINT_VERSION=1.7.8' | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    function Get-ContainerActionlintVersion {
      param([string]$Image, [string[]]$Arguments)
      return '1.7.8'
    }

    $invocation = Resolve-ActionlintContainerInvocation -RepoRoot $repoRoot -UseToolsImage -ToolsImageTag 'ghcr.io/example/comparevi-tools:latest'

    $invocation.image | Should -Be 'ghcr.io/example/comparevi-tools:latest'
    @($invocation.arguments) | Should -Be @('actionlint', '-color')
    $invocation.source | Should -Be 'tools-image'
    $invocation.surface | Should -Be 'container-tools-image'
    $invocation.fallbackReason | Should -Be ''
  }

  It 'falls back to the official image when the tools image actionlint version is stale' {
    $repoRoot = Join-Path $TestDrive 'repo-fallback'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    'ARG ACTIONLINT_VERSION=1.7.8' | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    function Get-ContainerActionlintVersion {
      param([string]$Image, [string[]]$Arguments)
      return '1.7.7'
    }

    $invocation = Resolve-ActionlintContainerInvocation -RepoRoot $repoRoot -UseToolsImage -ToolsImageTag 'ghcr.io/example/comparevi-tools:latest'

    $invocation.image | Should -Be 'rhysd/actionlint:1.7.8'
    @($invocation.arguments) | Should -Be @('-color')
    $invocation.source | Should -Be 'official-image-fallback'
    $invocation.surface | Should -Be 'container-official-fallback'
    $invocation.detectedVersion | Should -Be '1.7.7'
    $invocation.fallbackReason | Should -Be 'tools-image-stale'
  }
}
