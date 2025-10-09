Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Dev Dashboard loaders' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $modulePath = Join-Path $repoRoot 'tools' 'Dev-Dashboard.psm1'
    Import-Module $modulePath -Force
    $script:samplesRoot = Join-Path $repoRoot 'tools' 'dashboard' 'samples'
    $script:stakeholderPath = Join-Path $repoRoot 'tools' 'dashboard' 'stakeholders.json'
  }

  It 'parses session lock telemetry when files present' {
    $status = Get-SessionLockStatus -Group 'pester-selfhosted' -LockRoot $script:samplesRoot
    $status.Exists | Should -BeTrue
    $status.Status | Should -Be 'acquired'
    $status.QueueWaitSeconds | Should -Be 30
    $status.LockPath | Should -Match 'lock.json$'
  }

  It 'loads Pester telemetry totals and failures' {
    $telemetry = Get-PesterTelemetry -ResultsRoot $script:samplesRoot
    $telemetry.Totals.Total | Should -Be 58
    $telemetry.Totals.Passed | Should -Be 57
    $telemetry.Totals.Failed | Should -Be 1
    $telemetry.DispatcherErrors.Count | Should -BeGreaterThan 0
    $telemetry.FailedTests.Name | Should -Contain 'Queue timeout'
  }

  It 'loads Agent-Wait telemetry' {
    $wait = Get-AgentWaitTelemetry -ResultsRoot $script:samplesRoot
    $wait.Exists | Should -BeTrue
    $wait.Reason | Should -Be 'session-lock'
    $wait.DurationSeconds | Should -Be 45
    $wait.History.Count | Should -Be 2
    $wait.Longest.Elapsed | Should -Be 390
    ($wait.History | Where-Object { $_.WithinMargin -eq $false }).Count | Should -BeGreaterThan 0
  }

  It 'loads LabVIEW snapshot telemetry' {
    $snapshotPath = Join-Path $script:samplesRoot 'labview-processes.json'
    $lv = Get-LabVIEWSnapshot -SnapshotPath $snapshotPath
    $lv.Exists | Should -BeTrue
    $lv.ProcessCount | Should -Be 1
    $lv.LabVIEW.Count | Should -Be 1
    $lv.LVCompare.Count | Should -Be 1
    $lv.LabVIEW.Processes[0].pid | Should -Be 4242
    $lv.LVCompare.Processes[0].pid | Should -Be 5151
  }

  It 'resolves stakeholder information from configuration' {
    $info = Get-StakeholderInfo -Group 'pester-selfhosted' -StakeholderPath $script:stakeholderPath
    $info.Found | Should -BeTrue
    $info.PrimaryOwner | Should -Be 'svelderrainruiz'
    $info.Channels | Should -Contain 'slack://#ci-selfhosted'
    $info.DxIssue | Should -Be 99
  }

  It 'produces action items from telemetry signals' {
    $session = [pscustomobject]@{
      Exists = $true
      Group = 'test-group'
      Status = 'takeover'
      LockDirectory = 'tests/results/_session_lock/test-group'
      QueueWaitSeconds = 420
      HeartbeatAgeSeconds = 300
      Takeover = $true
      TakeoverReason = 'stale heartbeat'
      Errors = @('lock.json corrupt')
    }
    $pester = [pscustomobject]@{
      Totals = [pscustomobject]@{
        Failed = 2
        Errors = 1
        Passed = 10
        Total = 12
      }
      DispatcherErrors = @('failure parsing results')
      DispatcherWarnings = @()
      ResultsPath = 'tests/results/pester-results.xml'
      SummaryPath = 'tests/results/pester-summary.json'
      Errors = @()
    }
    $wait = [pscustomobject]@{
      Exists = $true
      Reason = 'queue'
      DurationSeconds = 700
      Errors = @()
      History = @(
        [pscustomobject]@{
          Reason = 'queue'
          Expected = 60
          Elapsed = 45
          WithinMargin = $true
          StartedAt = [DateTime]::UtcNow.AddMinutes(-20)
          EndedAt = [DateTime]::UtcNow.AddMinutes(-19)
        },
        [pscustomobject]@{
          Reason = 'queue follow-up'
          Expected = 60
          Elapsed = 720
          WithinMargin = $false
          StartedAt = [DateTime]::UtcNow.AddMinutes(-5)
          EndedAt = [DateTime]::UtcNow.AddMinutes(-0.5)
        }
      )
      Longest = [pscustomobject]@{
        Reason = 'queue follow-up'
        Elapsed = 720
        WithinMargin = $false
      }
    }
    $stake = [pscustomobject]@{
      Group = 'test-group'
      Found = $false
      PrimaryOwner = $null
      Backup = $null
      Channels = @()
      DxIssue = $null
      ConfigPath = 'config.json'
      Errors = @()
    }

    $labview = [pscustomobject]@{
      ProcessCount = 2
      Processes = @(
        [pscustomobject]@{ pid = 111; startTimeUtc = (Get-Date).ToString('o'); workingSetBytes = 1024; totalCpuSeconds = 5 },
        [pscustomobject]@{ pid = 222; startTimeUtc = (Get-Date).AddMinutes(-2).ToString('o'); workingSetBytes = 2048; totalCpuSeconds = 7 }
      )
      LabVIEW = [pscustomobject]@{
        Count = 2
        Processes = @(
          [pscustomobject]@{ pid = 111 },
          [pscustomobject]@{ pid = 222 }
        )
      }
      LVCompare = [pscustomobject]@{
        Count = 1
        Processes = @(
          [pscustomobject]@{ pid = 333 }
        )
      }
      Errors = @()
    }

    $items = Get-ActionItems -SessionLock $session -PesterTelemetry $pester -AgentWait $wait -Stakeholder $stake -WatchTelemetry $null -LabVIEWSnapshot $labview
    $items | Should -Not -BeNullOrEmpty
    $sessionItems = $items | Where-Object { $_.Category -eq 'SessionLock' }
    $sessionItems.Count | Should -BeGreaterThan 0
    ($sessionItems | Where-Object { $_.Message -match 'Queue wait reached' }).Count | Should -BeGreaterThan 0
    ($sessionItems | Where-Object { $_.Message -match 'takeover recorded' }).Count | Should -BeGreaterThan 0
    ($sessionItems | Where-Object { $_.Message -match 'Unable to load session lock artifact' }).Count | Should -BeGreaterThan 0
    ($items | Where-Object { $_.Category -eq 'Pester' } | Measure-Object).Count | Should -BeGreaterThan 0
    $queueItems = @($items | Where-Object { $_.Category -eq 'Queue' })
    $queueItems.Count | Should -BeGreaterThan 0
    @($queueItems | Where-Object { $_.Message -match 'exceeded tolerance' }).Count | Should -BeGreaterThan 0
    @($queueItems | Where-Object { $_.Message -match 'Longest recorded' }).Count | Should -BeGreaterThan 0
    ($items | Where-Object { $_.Category -eq 'Stakeholders' } | Measure-Object).Count | Should -BeGreaterThan 0
    ($items | Where-Object { $_.Category -eq 'LabVIEW' -and $_.Message -match 'LVCompare' }).Count | Should -Be 1
  }

  It 'references stakeholder dx issue when available' {
    $session = [pscustomobject]@{
      Exists = $true
      Status = 'acquired'
      QueueWaitSeconds = 0
      HeartbeatAgeSeconds = 0
      Takeover = $false
      TakeoverReason = $null
      Errors = @()
    }
    $pester = [pscustomobject]@{
      Totals = [pscustomobject]@{ Failed = 0; Errors = 0 }
      DispatcherErrors = @()
      DispatcherWarnings = @()
      ResultsPath = $null
      SummaryPath = $null
      Errors = @()
    }
    $wait = [pscustomobject]@{
      Exists = $false
      Errors = @()
      History = @()
    }
    $stake = [pscustomobject]@{
      Group = 'pester-selfhosted'
      Found = $true
      PrimaryOwner = 'owner'
      Backup = $null
      Channels = @('slack://#ci-selfhosted')
      DxIssue = 99
      ConfigPath = 'tools/dashboard/stakeholders.json'
      Errors = @()
    }

    $items = Get-ActionItems -SessionLock $session -PesterTelemetry $pester -AgentWait $wait -Stakeholder $stake
    $dxItem = $items | Where-Object { $_.Category -eq 'Stakeholders' -and $_.Message -match '#99' }
    $dxItem | Should -Not -BeNullOrEmpty
  }
}
