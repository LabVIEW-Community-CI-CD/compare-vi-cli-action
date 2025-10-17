Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LabVIEWPidTracker module' -Tag 'Unit' {
  BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'tools' 'LabVIEWPidTracker.psm1'
    Import-Module $modulePath -Force
  }

  It 'writes tracker with null pid when no LabVIEW process is present' {
    $tracker = Join-Path $TestDrive 'labview.json'
    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @() }
    Mock -CommandName Get-Process -ParameterFilter { $Id } -MockWith { throw "process not found" }

    $result = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'

    Test-Path -LiteralPath $tracker | Should -BeTrue
    $result.Pid | Should -BeNullOrEmpty
    $result.Running | Should -BeFalse
    $result.Reused | Should -BeFalse

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.schema | Should -Be 'labview-pid-tracker/v1'
    $json.pid | Should -BeNullOrEmpty
    $json.running | Should -BeFalse
  }

  It 'reuses existing pid when tracker file references a running LabVIEW.exe' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $existing = [ordered]@{
      schema       = 'labview-pid-tracker/v1'
      updatedAt    = (Get-Date).ToString('o')
      pid          = 4242
      running      = $true
      reused       = $false
      source       = 'seed'
      observations = @()
    }
    $existing | ConvertTo-Json -Depth 4 | Out-File -FilePath $tracker -Encoding utf8

    $procObj = [pscustomobject]@{ Id = 4242; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-5) }
    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($procObj) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 4242 } -MockWith { $procObj }

    $result = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'

    $result.Pid | Should -Be 4242
    $result.Reused | Should -BeTrue
    $result.Running | Should -BeTrue
  }

  It 'selects a new pid when existing tracker entry is stale' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $stale = [ordered]@{
      schema       = 'labview-pid-tracker/v1'
      updatedAt    = (Get-Date).ToString('o')
      pid          = 100
      running      = $false
      reused       = $false
      source       = 'seed'
      observations = @()
    }
    $stale | ConvertTo-Json -Depth 4 | Out-File -FilePath $tracker -Encoding utf8

    $candidate = [pscustomobject]@{ Id = 5555; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-1) }
    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($candidate) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 100 } -MockWith { throw "process missing" }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 5555 } -MockWith { $candidate }

    $result = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'

    $result.Pid | Should -Be 5555
    $result.Reused | Should -BeFalse
    $result.Running | Should -BeTrue
  }

  It 'finalizes tracker and records running state' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $proc = [pscustomobject]@{ Id = 3210; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-2) }

    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($proc) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 3210 } -MockWith { $proc }

    $init = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'
    $init.Pid | Should -Be 3210

    $final = Stop-LabVIEWPidTracker -TrackerPath $tracker -Pid $init.Pid -Source 'test:final'
    $final.Pid | Should -Be 3210
    $final.Running | Should -BeTrue
    $final.Reused | Should -BeFalse
    $final.Observation.reused | Should -BeFalse

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.running | Should -BeTrue
    ($json.observations | Measure-Object).Count | Should -BeGreaterThan 0
    $json.observations[-1].reused | Should -BeFalse
  }

  It 'persists context data when provided during finalization' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $proc = [pscustomobject]@{ Id = 777; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-3) }

    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($proc) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 777 } -MockWith { $proc }

    $init = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'
    $context = [ordered]@{ stage = 'unit-test'; total = 5; failed = 1; timedOut = $false }

    $final = Stop-LabVIEWPidTracker -TrackerPath $tracker -Pid $init.Pid -Source 'test:context' -Context $context
    $final.Pid | Should -Be 777
    $final.Observation.context.stage | Should -Be 'unit-test'
    $final.Observation.context.total | Should -Be 5
    $final.Observation.contextSource | Should -Be 'test:context'
    $final.Observation.contextSourceDetail | Should -Be 'test:context'
    $final.Context.stage | Should -Be 'unit-test'
    $final.ContextSource | Should -Be 'test:context'
    $final.ContextSourceDetail | Should -Be 'test:context'

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.context.stage | Should -Be 'unit-test'
    $json.observations[-1].context.failed | Should -Be 1
    $json.contextSource | Should -Be 'test:context'
    $json.contextSourceDetail | Should -Be 'test:context'
    $json.observations[-1].contextSourceDetail | Should -Be 'test:context'
  }

  It 'allows overriding context source detail' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $proc = [pscustomobject]@{ Id = 901; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-3) }

    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($proc) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 901 } -MockWith { $proc }

    $init = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'
    $context = [ordered]@{ stage = 'detail-test'; info = 'custom' }

    $final = Stop-LabVIEWPidTracker -TrackerPath $tracker -Pid $init.Pid -Source 'test:context' -Context $context -ContextSourceDetail 'detail:custom'
    $final.ContextSource | Should -Be 'test:context'
    $final.ContextSourceDetail | Should -Be 'detail:custom'
    $final.Observation.contextSourceDetail | Should -Be 'detail:custom'

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.contextSourceDetail | Should -Be 'detail:custom'
    $json.observations[-1].contextSourceDetail | Should -Be 'detail:custom'
  }

  It 'normalizes dictionary context blocks in deterministic order' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $proc = [pscustomobject]@{ Id = 889; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-6) }

    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($proc) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 889 } -MockWith { $proc }

    $init = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'
    $context = @{ zeta = 3; alpha = 1; beta = 2 }

    $final = Stop-LabVIEWPidTracker -TrackerPath $tracker -Pid $init.Pid -Source 'test:dict' -Context $context
    $final.Context.PSObject.Properties.Name | Should -Be @('alpha','beta','zeta')
    $final.Context.alpha | Should -Be 1

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.context.PSObject.Properties.Name | Should -Be @('alpha','beta','zeta')
    $json.context.alpha | Should -Be 1
    $json.observations[-1].context.beta | Should -Be 2
  }

  It 'normalizes PSCustomObject context blocks' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $proc = [pscustomobject]@{ Id = 888; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-4) }

    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($proc) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 888 } -MockWith { $proc }

    $init = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'
    $context = [pscustomobject]@{ stage = 'psco'; detail = 'example' }

    $final = Stop-LabVIEWPidTracker -TrackerPath $tracker -Pid $init.Pid -Source 'test:psco' -Context $context
    $final.Context.stage | Should -Be 'psco'
    $final.Context.detail | Should -Be 'example'

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.context.stage | Should -Be 'psco'
    $json.observations[-1].context.detail | Should -Be 'example'
  }

  It 'recursively normalizes nested context values including arrays' {
    $tracker = Join-Path $TestDrive 'labview.json'
    $proc = [pscustomobject]@{ Id = 4321; ProcessName = 'LabVIEW'; StartTime = (Get-Date).AddMinutes(-7) }

    Mock -CommandName Get-Process -ParameterFilter { $Name -eq 'LabVIEW' } -MockWith { @($proc) }
    Mock -CommandName Get-Process -ParameterFilter { $Id -eq 4321 } -MockWith { $proc }

    $init = Start-LabVIEWPidTracker -TrackerPath $tracker -Source 'test:init'
    $context = @{ 
      stage = 'nested'
      summary = @{
        failed = 1
        passed = 4
        details = @{ later = 'value'; earlier = 'first' }
      }
      buckets = @(
        @{ zulu = 26; alpha = 1 },
        [pscustomobject]@{ name = 'inner'; metrics = @{ delta = 4; beta = 2 } }
      )
    }

    $final = Stop-LabVIEWPidTracker -TrackerPath $tracker -Pid $init.Pid -Source 'test:nested' -Context $context

    $final.Context.stage | Should -Be 'nested'
    $final.Context.summary.PSObject.Properties.Name | Should -Be @('details','failed','passed')
    $final.Context.summary.details.PSObject.Properties.Name | Should -Be @('earlier','later')
    $final.Context.buckets.Count | Should -Be 2
    $final.Context.buckets[0].PSObject.Properties.Name | Should -Be @('alpha','zulu')
    $final.Context.buckets[1].metrics.PSObject.Properties.Name | Should -Be @('beta','delta')

    $resolved = Resolve-LabVIEWPidContext -Input $context
    $resolved.summary.details.PSObject.Properties.Name | Should -Be @('earlier','later')
    $resolved.buckets[1].metrics.delta | Should -Be 4

    $json = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $json.context.summary.details.earlier | Should -Be 'first'
    $json.context.buckets[0].alpha | Should -Be 1
    $json.contextSource | Should -Be 'test:nested'
  }

  It 'exposes Resolve-LabVIEWPidContext for callers needing manual normalization' {
    $command = Get-Command -Name Resolve-LabVIEWPidContext -ErrorAction Stop
    $command.CommandType | Should -Be 'Function'

    $ordered = Resolve-LabVIEWPidContext -Input @{ bravo = 2; alpha = 1 }
    $ordered.PSObject.Properties.Name | Should -Be @('alpha','bravo')
  }
}
