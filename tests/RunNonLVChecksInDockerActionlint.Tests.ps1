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

    foreach ($functionName in @(
      'Get-ActionlintVersionFloor',
      'Test-ActionlintVersionAtLeast',
      'Invoke-DockerCliCapture',
      'Test-IsMutableToolsImageReference',
      'Get-ContainerImageRepoDigest',
      'Resolve-ToolsImageVerificationEvidence',
      'Invoke-ContainerCapture',
      'Get-ContainerActionlintVersion',
      'Resolve-ActionlintContainerInvocation'
    )) {
      Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName $functionName)
    }
  }

  It 'reads the actionlint version floor from the tools Dockerfile' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    @"
# syntax=docker/dockerfile:1
ARG ACTIONLINT_VERSION=1.7.8
"@ | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    $version = Get-ActionlintVersionFloor -RepoRoot $repoRoot

    $version | Should -Be '1.7.8'
  }

  It 'compares actionlint versions against the required floor' {
    (Test-ActionlintVersionAtLeast -Version '1.7.7' -MinimumVersion '1.7.8') | Should -BeFalse
    (Test-ActionlintVersionAtLeast -Version '1.7.8' -MinimumVersion '1.7.8') | Should -BeTrue
    (Test-ActionlintVersionAtLeast -Version '1.8.0' -MinimumVersion '1.7.8') | Should -BeTrue
    (Test-ActionlintVersionAtLeast -Version '' -MinimumVersion '1.7.8') | Should -BeFalse
  }

  It 'detects which tools image references need pull-or-digest evidence' {
    (Test-IsMutableToolsImageReference -Image 'ghcr.io/example/comparevi-tools:latest') | Should -BeTrue
    (Test-IsMutableToolsImageReference -Image 'ghcr.io/example/comparevi-tools') | Should -BeTrue
    (Test-IsMutableToolsImageReference -Image 'ghcr.io/example/comparevi-tools:v0.6.3-tools.14') | Should -BeFalse
    (Test-IsMutableToolsImageReference -Image 'ghcr.io/example/comparevi-tools@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') | Should -BeFalse
    (Test-IsMutableToolsImageReference -Image 'comparevi-tools:local') | Should -BeFalse
  }

  It 'pulls mutable remote tools tags before using them as freshness evidence' {
    function Invoke-DockerCliCapture {
      param([string[]]$Arguments)
      if ($Arguments[0] -eq 'pull') {
        return [pscustomobject]@{ exitCode = 0; stdout = 'pulled'; stderr = '' }
      }
      throw 'unexpected docker invocation'
    }

    function Get-ContainerImageRepoDigest {
      param([string]$Image)
      return 'ghcr.io/example/comparevi-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }

    $evidence = Resolve-ToolsImageVerificationEvidence -Image 'ghcr.io/example/comparevi-tools:latest'

    $evidence.strategy | Should -Be 'pull-and-inspect'
    $evidence.pulled | Should -BeTrue
    $evidence.repoDigest | Should -Be 'ghcr.io/example/comparevi-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $evidence.evidenceRef | Should -Be 'ghcr.io/example/comparevi-tools@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  }

  It 'uses the tools image when a local tools tag satisfies the floor' {
    $repoRoot = Join-Path $TestDrive 'repo-tools'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    'ARG ACTIONLINT_VERSION=1.7.8' | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    function Resolve-ToolsImageVerificationEvidence {
      param([string]$Image)
      return [ordered]@{
        strategy = 'local-inspect'
        pulled = $false
        repoDigest = ''
        evidenceRef = $Image
      }
    }

    function Get-ContainerActionlintVersion {
      param([string]$Image, [string[]]$Arguments)
      return '1.7.8'
    }

    $invocation = Resolve-ActionlintContainerInvocation -RepoRoot $repoRoot -UseToolsImage -ToolsImageTag 'comparevi-tools:local'

    $invocation.image | Should -Be 'comparevi-tools:local'
    @($invocation.arguments) | Should -Be @('actionlint', '-color')
    $invocation.source | Should -Be 'tools-image'
    $invocation.surface | Should -Be 'container-tools-image'
    $invocation.verificationStrategy | Should -Be 'local-inspect'
    $invocation.pulledFresh | Should -BeFalse
    $invocation.fallbackReason | Should -Be ''
  }

  It 'keeps mutable-tag evidence when the refreshed tools image satisfies the floor' {
    $repoRoot = Join-Path $TestDrive 'repo-tools-pulled'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    'ARG ACTIONLINT_VERSION=1.7.8' | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    function Resolve-ToolsImageVerificationEvidence {
      param([string]$Image)
      return [ordered]@{
        strategy = 'pull-and-inspect'
        pulled = $true
        repoDigest = 'ghcr.io/example/comparevi-tools@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        evidenceRef = 'ghcr.io/example/comparevi-tools@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      }
    }

    function Get-ContainerActionlintVersion {
      param([string]$Image, [string[]]$Arguments)
      return '1.7.8'
    }

    $invocation = Resolve-ActionlintContainerInvocation -RepoRoot $repoRoot -UseToolsImage -ToolsImageTag 'ghcr.io/example/comparevi-tools:latest'

    $invocation.image | Should -Be 'ghcr.io/example/comparevi-tools:latest'
    $invocation.verificationStrategy | Should -Be 'pull-and-inspect'
    $invocation.verifiedRepoDigest | Should -Be 'ghcr.io/example/comparevi-tools@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $invocation.verificationEvidenceRef | Should -Be 'ghcr.io/example/comparevi-tools@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $invocation.pulledFresh | Should -BeTrue
    $invocation.fallbackReason | Should -Be ''
  }

  It 'falls back to the official image when the refreshed tools image is still stale' {
    $repoRoot = Join-Path $TestDrive 'repo-fallback'
    $dockerDir = Join-Path $repoRoot 'tools' 'docker'
    New-Item -ItemType Directory -Path $dockerDir -Force | Out-Null
    'ARG ACTIONLINT_VERSION=1.7.8' | Set-Content -LiteralPath (Join-Path $dockerDir 'Dockerfile.tools') -Encoding utf8

    function Resolve-ToolsImageVerificationEvidence {
      param([string]$Image)
      return [ordered]@{
        strategy = 'pull-and-inspect'
        pulled = $true
        repoDigest = 'ghcr.io/example/comparevi-tools@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        evidenceRef = 'ghcr.io/example/comparevi-tools@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
      }
    }

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
    $invocation.verificationStrategy | Should -Be 'pull-and-inspect'
    $invocation.verifiedRepoDigest | Should -Be 'ghcr.io/example/comparevi-tools@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
    $invocation.pulledFresh | Should -BeTrue
    $invocation.fallbackReason | Should -Be 'tools-image-stale'
  }
}