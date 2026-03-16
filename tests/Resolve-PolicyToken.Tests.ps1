[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-PolicyToken.ps1' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot 'tools/priority/Resolve-PolicyToken.ps1'
  }

  It 'adds Dependabot remediation when admin-capable token resolution fails' {
    function Invoke-RestMethod {
      [PSCustomObject]@{
        permissions = [PSCustomObject]@{
          admin = $false
        }
      }
    }

    try {
      $thrown = $null
      try {
        & $scriptPath `
          -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
          -PrimaryToken '' `
          -SecondaryToken 'read-only-token' `
          -TertiaryToken 'read-only-token' `
          -Actor 'dependabot[bot]' `
          -StepSummaryPath ''
      } catch {
        $thrown = $_.Exception
      }

      $thrown | Should -Not -BeNullOrEmpty
      $thrown.Message | Should -Match 'No admin-capable token resolved'
      $thrown.Message | Should -Match 'Dependabot-triggered runs use a separate secret scope'
      $thrown.Message | Should -Match 'gh secret set GH_TOKEN --repo LabVIEW-Community-CI-CD/compare-vi-cli-action --app dependabot'
    } finally {
      Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    }
  }

  It 'exports the selected token to GITHUB_ENV when an admin-capable token is available' {
    function Invoke-RestMethod {
      [PSCustomObject]@{
        permissions = [PSCustomObject]@{
          admin = $true
        }
      }
    }

    $envPath = Join-Path $TestDrive 'github.env'
    $summaryPath = Join-Path $TestDrive 'summary.md'
    $previousGitHubEnv = $env:GITHUB_ENV
    $hadGitHubEnv = Test-Path Env:\GITHUB_ENV
    $previousRunnerTemp = $env:RUNNER_TEMP
    $hadRunnerTemp = Test-Path Env:\RUNNER_TEMP
    $env:GITHUB_ENV = $envPath
    $env:RUNNER_TEMP = $TestDrive

    try {
      & $scriptPath `
        -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
        -PrimaryToken 'admin-token' `
        -SecondaryToken '' `
        -TertiaryToken '' `
        -TokenFileName 'policy-guard-gh-token.txt' `
        -Actor 'github-actions[bot]' `
        -StepSummaryPath $summaryPath

      $envLines = Get-Content -LiteralPath $envPath
      $envLines | Should -Contain 'GH_TOKEN=admin-token'
      $envLines | Should -Contain 'POLICY_TOKEN_SOURCE=secrets.GH_TOKEN'
      $envLines | Should -Contain 'POLICY_TOKEN_REPOSITORY=LabVIEW-Community-CI-CD/compare-vi-cli-action'

      $tokenFile = Join-Path $TestDrive 'policy-guard-gh-token.txt'
      (Get-Content -LiteralPath $tokenFile -Raw) | Should -Be 'admin-token'
      (Get-Content -LiteralPath $summaryPath -Raw) | Should -Match 'Selected source: secrets.GH_TOKEN'
    } finally {
      if ($hadGitHubEnv) {
        $env:GITHUB_ENV = $previousGitHubEnv
      } else {
        Remove-Item Env:\GITHUB_ENV -ErrorAction SilentlyContinue
      }
      if ($hadRunnerTemp) {
        $env:RUNNER_TEMP = $previousRunnerTemp
      } else {
        Remove-Item Env:\RUNNER_TEMP -ErrorAction SilentlyContinue
      }
      Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    }
  }
}
