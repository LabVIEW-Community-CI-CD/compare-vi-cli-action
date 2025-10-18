Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'CompareVI provider router' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'tools' 'providers' 'ProviderRouter.psm1'
    Import-Module $modulePath -Force
    $script:cliScriptPath = Join-Path $repoRoot 'tools' 'CompareVI-CLI.ps1'
  }

  Context 'provider resolution' {
    It 'returns a deterministic plan for the mock provider' {
      $plan = Get-CompareVIProviderPlan -Operation RunVI -Provider mock -Parameters @{ viPath = 'Sample.vi' }
      $plan.provider.id        | Should -Be 'mock'
      $plan.operation.name     | Should -Be 'RunVI'
      $plan.binary              | Should -Match 'pwsh'
      $plan.arguments[-1]       | Should -Match '"viPath": "Sample.vi"'
    }

    It 'prefers LVCI_PROVIDER when provider is not supplied' {
      $previous = $env:LVCI_PROVIDER
      try {
        $env:LVCI_PROVIDER = 'mock'
        $plan = Get-CompareVIProviderPlan -Operation RunVI -Parameters @{ viPath = 'Env.vi' }
        $plan.provider.id | Should -Be 'mock'
      } finally {
        if ($null -eq $previous) {
          Remove-Item Env:LVCI_PROVIDER -ErrorAction SilentlyContinue
        } else {
          $env:LVCI_PROVIDER = $previous
        }
      }
    }

    It 'throws for unknown provider ids' {
      { Get-CompareVIProviderPlan -Operation RunVI -Provider missing -Parameters @{ viPath = 'Example.vi' } } | Should -Throw
    }
  }

  Context 'CLI entrypoint parameter merging' {
    It 'merges JSON file parameters with inline overrides' {
      $paramsPath = Join-Path $TestDrive 'params.json'
      @'
{
  "viPath": "File.vi",
  "showFP": true
}
'@ | Set-Content -Path $paramsPath -Encoding utf8

      $json = & $script:cliScriptPath -Operation RunVI -Provider mock -ParametersPath $paramsPath -Parameters @{ viPath = 'Inline.vi'; abortOnError = $true } -PlanOnly
      $plan = $json | ConvertFrom-Json -Depth 10

      $plan.provider.id | Should -Be 'mock'
      $plan.operation.name | Should -Be 'RunVI'
      $plan.arguments[-1] | Should -Match '"viPath": "Inline.vi"'
      $plan.arguments[-1] | Should -Match '"showFP": true'
      $plan.arguments[-1] | Should -Match '"abortOnError": true'
    }
  }

  Context 'operation validation' {
    It 'throws when operation metadata is missing' {
      { Get-CompareVIProviderPlan -Operation NotReal -Provider mock } | Should -Throw
    }
  }
}
