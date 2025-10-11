<#
  Integration-tagged smoke tests used when the runbook requests integration coverage.
  These avoid any LVCompare dependency so they can run on developer machines.
#>

Describe 'Runbook Integration Smoke' -Tag 'Integration','Runbook' {
  BeforeAll {
    $scriptPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-IntegrationRunbook.ps1')
  }

  It 'confirms the runbook script exists' {
    Test-Path $scriptPath | Should -BeTrue
  }

  It 'reports help synopsis via Get-Help' {
    $help = Get-Help $scriptPath -ErrorAction Stop
    $help.Synopsis | Should -Match 'Integration Runbook'
  }
}
