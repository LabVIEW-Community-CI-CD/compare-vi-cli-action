Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Session-Lock' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:sessionLockPath = Join-Path $repoRoot 'tools' 'Session-Lock.ps1'

    function script:Invoke-SessionLockProcess {
      param(
        [string[]]$Arguments,
        [hashtable]$EnvOverrides,
        [string]$WorkingDirectory
      )

      if (-not $EnvOverrides) { $EnvOverrides = @{} }

      $stdoutPath = [System.IO.Path]::GetTempFileName()
      $stderrPath = [System.IO.Path]::GetTempFileName()
      $arguments = @('-NoLogo', '-NoProfile', '-File', $script:sessionLockPath) + $Arguments

      $proc = Start-Process -FilePath (Get-Command pwsh).Source `
        -ArgumentList $arguments `
        -WorkingDirectory $WorkingDirectory `
        -NoNewWindow `
        -PassThru `
        -Wait `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Environment $EnvOverrides

      $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
      $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

      return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
      }
    }

    function script:Read-KeyValueFile {
      param([string]$Path)
      $map = @{}
      if (-not (Test-Path -LiteralPath $Path)) { return $map }
      foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
          $map[$matches.key] = $matches.value
        }
      }
      return $map
    }
  }

  BeforeEach {
    $script:workingDir = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Force -Path $script:workingDir | Out-Null

    $script:lockRoot = Join-Path $TestDrive 'locks'
    if (Test-Path -LiteralPath $script:lockRoot) {
      Remove-Item -LiteralPath $script:lockRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $script:lockRoot | Out-Null

    $script:envFile = Join-Path $TestDrive 'github_env.txt'
    $script:outFile = Join-Path $TestDrive 'github_output.txt'
    $script:summaryFile = Join-Path $TestDrive 'summary.md'

    $script:baseEnv = @{
      'SESSION_LOCK_ROOT'         = $script:lockRoot
      'GITHUB_ENV'                = $script:envFile
      'GITHUB_OUTPUT'             = $script:outFile
      'GITHUB_STEP_SUMMARY'       = $script:summaryFile
      'SESSION_GROUP'             = 'unit-test'
      'SESSION_QUEUE_WAIT_SECONDS' = '1'
      'SESSION_QUEUE_MAX_ATTEMPTS' = '2'
      'SESSION_STALE_SECONDS'      = '60'
      'SESSION_HEARTBEAT_SECONDS'  = '1'
    }
  }

  AfterEach {
    foreach ($name in @(
        'SESSION_LOCK_ROOT',
        'SESSION_GROUP',
        'SESSION_QUEUE_WAIT_SECONDS',
        'SESSION_QUEUE_MAX_ATTEMPTS',
        'SESSION_STALE_SECONDS',
        'SESSION_HEARTBEAT_SECONDS',
        'SESSION_FORCE_TAKEOVER',
        'SESSION_LOCK_ID'
      )) {
      Remove-Item -Path ("Env:$name") -ErrorAction SilentlyContinue
    }
    Remove-Item -Path Env:GITHUB_ENV -ErrorAction SilentlyContinue
    Remove-Item -Path Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
  }

  It 'acquires and releases the lock' {
    $result = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $result.ExitCode | Should -Be 0

    $envMap = Read-KeyValueFile -Path $script:envFile
    $envMap.ContainsKey('SESSION_LOCK_ID') | Should -BeTrue
    $lockId = $envMap['SESSION_LOCK_ID']
    $lockPath = Join-Path $script:lockRoot 'unit-test' 'lock.json'
    Test-Path -LiteralPath $lockPath | Should -BeTrue
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $lock.lockId | Should -Be $lockId

    $releaseEnv = $script:baseEnv.Clone()
    $releaseEnv['SESSION_LOCK_ID'] = $lockId
    $result = Invoke-SessionLockProcess -Arguments @('-Action', 'Release') -EnvOverrides $releaseEnv -WorkingDirectory $script:workingDir
    $result.ExitCode | Should -Be 0
    Test-Path -LiteralPath $lockPath | Should -BeFalse
  }

  It 'times out when lock is held' {
    $first = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $first.ExitCode | Should -Be 0
    $envMap = Read-KeyValueFile -Path $script:envFile
    $lockId = $envMap['SESSION_LOCK_ID']

    $secondOut = Join-Path $TestDrive 'out-second.txt'
    $secondEnv = $script:baseEnv.Clone()
    $secondEnv['GITHUB_OUTPUT'] = $secondOut
    $result = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $secondEnv -WorkingDirectory $script:workingDir
    $result.ExitCode | Should -Be 11

    $releaseEnv = $script:baseEnv.Clone()
    $releaseEnv['SESSION_LOCK_ID'] = $lockId
    Invoke-SessionLockProcess -Arguments @('-Action', 'Release') -EnvOverrides $releaseEnv -WorkingDirectory $script:workingDir | Out-Null
  }

  It 'detects stale lock without takeover' {
    $acquire = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $acquire.ExitCode | Should -Be 0
    $lockPath = Join-Path $script:lockRoot 'unit-test' 'lock.json'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $lock.heartbeatAt = ([DateTime]::UtcNow.AddSeconds(-600)).ToString('o')
    $lock | ConvertTo-Json -Depth 6 | Out-File -FilePath $lockPath -Encoding utf8

    $result = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire', '-StaleSeconds', '60') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $result.ExitCode | Should -Be 10
  }

  It 'takes over stale lock with ForceTakeover' {
    $acquire = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $acquire.ExitCode | Should -Be 0
    $lockPath = Join-Path $script:lockRoot 'unit-test' 'lock.json'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $lock.heartbeatAt = ([DateTime]::UtcNow.AddSeconds(-600)).ToString('o')
    $lock | ConvertTo-Json -Depth 6 | Out-File -FilePath $lockPath -Encoding utf8

    $envTakeover = $script:baseEnv.Clone()
    $envTakeover['SESSION_FORCE_TAKEOVER'] = '1'
    $result = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire', '-StaleSeconds', '60') -EnvOverrides $envTakeover -WorkingDirectory $script:workingDir
    $result.ExitCode | Should -Be 0
  }

  It 'updates heartbeat' {
    $acquire = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $acquire.ExitCode | Should -Be 0
    $lockPath = Join-Path $script:lockRoot 'unit-test' 'lock.json'
    $envMap = Read-KeyValueFile -Path $script:envFile
    $lockId = $envMap['SESSION_LOCK_ID']

    $heartbeatEnv = $script:baseEnv.Clone()
    $heartbeatEnv['SESSION_LOCK_ID'] = $lockId
    Start-Sleep -Seconds 1
    $hb = Invoke-SessionLockProcess -Arguments @('-Action', 'Heartbeat') -EnvOverrides $heartbeatEnv -WorkingDirectory $script:workingDir
    $hb.ExitCode | Should -Be 0

    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $age = ([DateTime]::UtcNow - [DateTime]::Parse($lock.heartbeatAt)).TotalSeconds
    $age | Should -BeLessThan 5
  }

  It 'inspects lock state' {
    $acquire = Invoke-SessionLockProcess -Arguments @('-Action', 'Acquire') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $acquire.ExitCode | Should -Be 0

    $inspect = Invoke-SessionLockProcess -Arguments @('-Action', 'Inspect') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $inspect.ExitCode | Should -Be 0
    $inspect.StdOut | Should -Match 'Group'

    $envMap = Read-KeyValueFile -Path $script:envFile
    $releaseEnv = $script:baseEnv.Clone()
    $releaseEnv['SESSION_LOCK_ID'] = $envMap['SESSION_LOCK_ID']
    Invoke-SessionLockProcess -Arguments @('-Action', 'Release') -EnvOverrides $releaseEnv -WorkingDirectory $script:workingDir | Out-Null

    $inspect = Invoke-SessionLockProcess -Arguments @('-Action', 'Inspect') -EnvOverrides $script:baseEnv -WorkingDirectory $script:workingDir
    $inspect.ExitCode | Should -Be 1
  }
}
