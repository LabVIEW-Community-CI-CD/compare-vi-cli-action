Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LabVIEW CLI PID tracker integration' -Tag 'Unit' {
  BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'tools' 'LabVIEWCli.psm1'
    Import-Module $modulePath -Force
  }

  It 'finalizes tracker and attaches metadata on successful operations' {
    $result = InModuleScope LabVIEWCli {
      param($testDrivePath)

      $originalRoot = $script:RepoRoot
      $script:RepoRoot = $testDrivePath

      $providerName = 'pester-cli-provider'
      $provider = New-Object psobject
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name Name -Value { 'pester-cli-provider' }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name ResolveBinaryPath -Value {
        (Get-Command -Name node -ErrorAction Stop).Source
      }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name Supports -Value {
        param($operation)
        return $true
      }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name BuildArgs -Value {
        param($operation, $params)
        @('-e','process.exit(0)')
      }

      try {
        if ($script:Providers.ContainsKey($providerName.ToLowerInvariant())) {
          $script:Providers.Remove($providerName.ToLowerInvariant()) | Out-Null
        }
        Register-LVProvider -Provider $provider
        Invoke-LVOperation -Operation 'CloseLabVIEW' -Provider $providerName -TimeoutSeconds 30
      } finally {
        if ($script:Providers.ContainsKey($providerName.ToLowerInvariant())) {
          $script:Providers.Remove($providerName.ToLowerInvariant()) | Out-Null
        }
        $script:RepoRoot = $originalRoot
      }
    } -ArgumentList $TestDrive

    $trackerPath = Join-Path $TestDrive 'tests/results/_cli/_agent/labview-pid.json'
    Test-Path -LiteralPath $trackerPath | Should -BeTrue

    $result | Should -Not -BeNullOrEmpty
    $result.labviewPidTracker.enabled | Should -BeTrue
    $result.labviewPidTracker.path | Should -Be $trackerPath
    $result.labviewPidTracker.relativePath | Should -Be 'tests/results/_cli/_agent/labview-pid.json'
    $result.labviewPidTracker.pathExists | Should -BeTrue
    $result.labviewPidTracker.finalized | Should -BeTrue
    $result.labviewPidTracker.length | Should -BeGreaterThan 0
    [string]::IsNullOrWhiteSpace($result.labviewPidTracker.lastWriteTimeUtc) | Should -BeFalse
    $result.labviewPidTracker.final.context.stage | Should -Be 'labview-cli:operation'
    $result.labviewPidTracker.final.context.provider | Should -Be 'pester-cli-provider'
    $result.labviewPidTracker.final.context.args | Should -Be @('-e','process.exit(0)')
    $result.labviewPidTracker.final.context.exitCode | Should -Be 0
    $result.labviewPidTracker.final.contextSource | Should -Be 'labview-cli:operation'

    $modulePayload = InModuleScope LabVIEWCli { Get-LabVIEWCliPidTracker }
    $modulePayload | Should -Not -BeNullOrEmpty
    $modulePayload.path | Should -Be $trackerPath
    $modulePayload.pathExists | Should -BeTrue
    $modulePayload.finalized | Should -BeTrue
    $modulePayload.final.context.stage | Should -Be 'labview-cli:operation'
  }

  It 'captures error context when the provider fails to start' {
    $outcome = InModuleScope LabVIEWCli {
      param($testDrivePath)

      $originalRoot = $script:RepoRoot
      $script:RepoRoot = $testDrivePath

      $providerName = 'pester-cli-error'
      $provider = New-Object psobject
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name Name -Value { 'pester-cli-error' }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name ResolveBinaryPath -Value {
        Join-Path $testDrivePath 'missing-cli.exe'
      }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name Supports -Value {
        param($operation)
        return $true
      }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name BuildArgs -Value {
        param($operation, $params)
        @()
      }

      $errorRecord = $null
      try {
        if ($script:Providers.ContainsKey($providerName.ToLowerInvariant())) {
          $script:Providers.Remove($providerName.ToLowerInvariant()) | Out-Null
        }
        Register-LVProvider -Provider $provider
        Invoke-LVOperation -Operation 'CloseLabVIEW' -Provider $providerName -TimeoutSeconds 5 | Out-Null
      } catch {
        $errorRecord = $_
      } finally {
        if ($script:Providers.ContainsKey($providerName.ToLowerInvariant())) {
          $script:Providers.Remove($providerName.ToLowerInvariant()) | Out-Null
        }
        $script:RepoRoot = $originalRoot
      }

      $trackerPath = Join-Path $testDrivePath 'tests/results/_cli/_agent/labview-pid.json'
      return @{ Error = $errorRecord; TrackerPath = $trackerPath }
    } -ArgumentList $TestDrive

    $outcome.Error | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $outcome.TrackerPath | Should -BeTrue

    $json = Get-Content -LiteralPath $outcome.TrackerPath -Raw | ConvertFrom-Json -Depth 6
    $json.context.stage | Should -Be 'labview-cli:error'
    $json.context.error | Should -Not -BeNullOrEmpty
    $json.context.provider | Should -Be 'pester-cli-error'
    $json.contextSource | Should -Be 'labview-cli:error'
  }

  It 'finalizes tracker even when headless guard setup fails' {
    $outcome = InModuleScope LabVIEWCli {
      param($testDrivePath)

      $originalRoot = $script:RepoRoot
      $script:RepoRoot = $testDrivePath

      $providerName = 'pester-cli-guard'
      $provider = New-Object psobject
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name Name -Value { 'pester-cli-guard' }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name ResolveBinaryPath -Value {
        (Get-Command -Name node -ErrorAction Stop).Source
      }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name Supports -Value {
        param($operation)
        return $true
      }
      Add-Member -InputObject $provider -MemberType ScriptMethod -Name BuildArgs -Value {
        param($operation, $params)
        @('-e','process.exit(0)')
      }

      $originalGuard = Get-Item function:Set-LVHeadlessEnv -ErrorAction SilentlyContinue
      function Set-LVHeadlessEnv {
        throw 'headless guard failure'
      }

      $errorRecord = $null
      try {
        if ($script:Providers.ContainsKey($providerName.ToLowerInvariant())) {
          $script:Providers.Remove($providerName.ToLowerInvariant()) | Out-Null
        }
        Register-LVProvider -Provider $provider
        Invoke-LVOperation -Operation 'CloseLabVIEW' -Provider $providerName -TimeoutSeconds 5 | Out-Null
      } catch {
        $errorRecord = $_
      } finally {
        if ($script:Providers.ContainsKey($providerName.ToLowerInvariant())) {
          $script:Providers.Remove($providerName.ToLowerInvariant()) | Out-Null
        }
        if ($originalGuard) {
          Set-Item -Path Function:Set-LVHeadlessEnv -Value $originalGuard.ScriptBlock
        } else {
          Remove-Item -Path Function:Set-LVHeadlessEnv -ErrorAction SilentlyContinue
        }
        $script:RepoRoot = $originalRoot
      }

      $trackerPath = Join-Path $testDrivePath 'tests/results/_cli/_agent/labview-pid.json'
      return @{
        Error = $errorRecord
        TrackerPath = $trackerPath
        Payload = Get-LabVIEWCliPidTracker
      }
    } -ArgumentList $TestDrive

    $outcome.Error | Should -Not -BeNullOrEmpty
    $outcome.Error.Exception.Message | Should -Match 'headless guard failure'
    Test-Path -LiteralPath $outcome.TrackerPath | Should -BeTrue

    $json = Get-Content -LiteralPath $outcome.TrackerPath -Raw | ConvertFrom-Json -Depth 6
    $json.context.stage | Should -Be 'labview-cli:error'
    $json.context.error | Should -Match 'headless guard failure'

    $outcome.Payload | Should -Not -BeNullOrEmpty
    $outcome.Payload.finalized | Should -BeTrue
    $outcome.Payload.final.context.stage | Should -Be 'labview-cli:error'
    $outcome.Payload.final.context.error | Should -Match 'headless guard failure'
  }
}
