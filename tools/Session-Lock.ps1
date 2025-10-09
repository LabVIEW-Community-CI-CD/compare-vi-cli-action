param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Acquire','Release','Heartbeat','Inspect')]
  [string]$Action,

  [string]$Group,

  [int]$QueueWaitSeconds,
  [int]$QueueMaxAttempts,
  [int]$StaleSeconds,
  [int]$HeartbeatSeconds,

  [switch]$ForceTakeover,

  [string]$LockRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SessionName {
  try {
    if ($env:PS_SESSION_NAME -and $env:PS_SESSION_NAME -ne '') { return $env:PS_SESSION_NAME }
    if ($env:AGENT_SESSION_NAME -and $env:AGENT_SESSION_NAME -ne '') { return $env:AGENT_SESSION_NAME }
  } catch {}
  return ("session-lock:{0}" -f $PID)
}
${script:SessionName} = Get-SessionName

function Convert-ToEnvName {
  param([string]$Name)
  if (-not $Name) { return 'SESSION_' }
  $builder = New-Object System.Text.StringBuilder
  $chars = $Name.ToCharArray()
  for ($i = 0; $i -lt $chars.Length; $i++) {
    $char = $chars[$i]
    $isUpper = ([char]::IsUpper($char))
    if ($i -gt 0) {
      $prev = $chars[$i - 1]
      $prevIsLowerOrDigit = [char]::IsLower($prev) -or [char]::IsDigit($prev)
      if ($isUpper -and $prevIsLowerOrDigit) {
        $null = $builder.Append('_')
      }
    }
    $null = $builder.Append([char]::ToUpperInvariant($char))
  }
  return 'SESSION_' + $builder.ToString()
}

function Get-ConfigValue {
  param(
    [string]$ParameterName,
    [object]$Default,
    [object]$CurrentValue,
    [switch]$AsInt,
    [switch]$AsSwitch,
    [bool]$IsExplicit = $false
  )
  if ($IsExplicit) {
    if ($AsSwitch) {
      if ($CurrentValue -is [System.Management.Automation.SwitchParameter]) {
        return $CurrentValue.IsPresent
      }
      if ($CurrentValue -is [bool]) { return $CurrentValue }
      return ($CurrentValue -eq 1 -or $CurrentValue -eq '1' -or $CurrentValue -eq 'true')
    }
    if ($AsInt) {
      if ($CurrentValue -is [int]) { return [int]$CurrentValue }
      if ($CurrentValue -is [double]) { return [int][double]$CurrentValue }
      if (-not [string]::IsNullOrEmpty($CurrentValue) -and [double]::TryParse([string]$CurrentValue, [ref]([double]0))) {
        return [int][double]::Parse([string]$CurrentValue, [System.Globalization.CultureInfo]::InvariantCulture)
      }
      return $Default
    }
    if ($null -ne $CurrentValue -and $CurrentValue -ne '') { return $CurrentValue }
  }

  $envName = Convert-ToEnvName -Name $ParameterName
  $raw = [System.Environment]::GetEnvironmentVariable($envName)
  if ($AsSwitch) {
    if (-not [string]::IsNullOrEmpty($raw)) { return ($raw -eq '1' -or $raw -eq 'true') }
    return ($Default -eq $true)
  }
  if ($AsInt) {
    if (-not [string]::IsNullOrEmpty($raw) -and [double]::TryParse($raw, [ref]([double]0))) {
      return [int][double]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $Default
  }
  if (-not [string]::IsNullOrEmpty($raw)) { return $raw }
  return $Default
}

$Group = Get-ConfigValue -ParameterName 'Group' -Default 'pester-selfhosted' -CurrentValue $Group -IsExplicit ($PSBoundParameters.ContainsKey('Group'))
$QueueWaitSeconds = Get-ConfigValue -ParameterName 'QueueWaitSeconds' -Default 15 -CurrentValue $QueueWaitSeconds -AsInt -IsExplicit ($PSBoundParameters.ContainsKey('QueueWaitSeconds'))
$QueueMaxAttempts = Get-ConfigValue -ParameterName 'QueueMaxAttempts' -Default 40 -CurrentValue $QueueMaxAttempts -AsInt -IsExplicit ($PSBoundParameters.ContainsKey('QueueMaxAttempts'))
$StaleSeconds = Get-ConfigValue -ParameterName 'StaleSeconds' -Default 180 -CurrentValue $StaleSeconds -AsInt -IsExplicit ($PSBoundParameters.ContainsKey('StaleSeconds'))
$HeartbeatSeconds = Get-ConfigValue -ParameterName 'HeartbeatSeconds' -Default 15 -CurrentValue $HeartbeatSeconds -AsInt -IsExplicit ($PSBoundParameters.ContainsKey('HeartbeatSeconds'))
$ForceTakeover = Get-ConfigValue -ParameterName 'ForceTakeover' -Default $false -CurrentValue $ForceTakeover -AsSwitch -IsExplicit ($PSBoundParameters.ContainsKey('ForceTakeover'))
$LockRoot = Get-ConfigValue -ParameterName 'LockRoot' -Default $LockRoot -CurrentValue $LockRoot -IsExplicit ($PSBoundParameters.ContainsKey('LockRoot'))

try { Write-Host "::notice::[ps-session:$script:SessionName pid=$PID action=$Action group=$Group]" } catch {}

if (-not $LockRoot) {
  if ($env:SESSION_LOCK_ROOT) {
    $LockRoot = $env:SESSION_LOCK_ROOT
  } else {
    $LockRoot = Join-Path (Resolve-Path '.').Path 'tests/results/_session_lock'
  }
}

function Get-LockDirectory {
  $dir = Join-Path $LockRoot $Group
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  return $dir
}

function Get-LockPath {
  return Join-Path (Get-LockDirectory) 'lock.json'
}

function Get-StatusPath {
  return Join-Path (Get-LockDirectory) 'status.md'
}

function Read-Lock {
  $path = Get-LockPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $json = Get-Content -LiteralPath $path -Raw -Encoding utf8
    if (-not $json) { return $null }
    return $json | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Write-Lock {
  param(
    [Parameter(Mandatory)]$Record,
    [switch]$CreateNew
  )
  $path = Get-LockPath
  $mode = $CreateNew ? [System.IO.FileMode]::CreateNew : [System.IO.FileMode]::Create
  $json = $Record | ConvertTo-Json -Depth 6
  $fs = [System.IO.File]::Open($path, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
    try { $writer.Write($json) }
    finally { $writer.Dispose() }
  } finally { $fs.Dispose() }
  return $path
}

function Write-OutputValue {
  param([string]$Key,[object]$Value)
  if (-not $Key) { return }
  $outFile = $env:GITHUB_OUTPUT
  if ($outFile) {
    "$Key=$Value" | Out-File -FilePath $outFile -Append -Encoding utf8
  }
}

function Write-EnvValue {
  param([string]$Key,[object]$Value)
  if (-not $Key) { return }
  $envFile = $env:GITHUB_ENV
  if ($envFile) {
    "$Key=$Value" | Out-File -FilePath $envFile -Append -Encoding utf8
  }
}

function Write-Summary {
  param([string[]]$Lines)
  $summary = $env:GITHUB_STEP_SUMMARY
  if ($summary -and $Lines) {
    $Lines -join "`n" | Out-File -FilePath $summary -Append -Encoding utf8
  }
}

function Write-StatusFile {
  param([string[]]$Lines)
  $statusPath = Get-StatusPath
  if ($Lines) {
    $Lines -join "`n" | Out-File -FilePath $statusPath -Encoding utf8
  }
}

function Write-Summary {
  param([string[]]$Lines)
  $summary = $env:GITHUB_STEP_SUMMARY
  if ($summary -and $Lines) {
    $Lines -join "`n" | Out-File -FilePath $summary -Append -Encoding utf8
  }
}

function New-LockRecord {
  param(
    [string]$LockId,
    [DateTime]$AcquiredAt,
    [int]$QueueWaitSeconds,
    [string]$TakeoverReason
  )
  $record = [ordered]@{
    lockId = $LockId
    group = $Group
    sessionName = $script:SessionName
    queueWaitSeconds = $QueueWaitSeconds
    workflow = $env:GITHUB_WORKFLOW
    job = $env:GITHUB_JOB
    runId = $env:GITHUB_RUN_ID
    runAttempt = $env:GITHUB_RUN_ATTEMPT
    actor = $env:GITHUB_ACTOR
    machine = $env:COMPUTERNAME
    processId = $PID
    acquiredAt = $AcquiredAt.ToUniversalTime().ToString('o')
    heartbeatAt = $AcquiredAt.ToUniversalTime().ToString('o')
  }
  if ($TakeoverReason) {
    $record.takeover = $true
    $record.takeoverReason = $TakeoverReason
  }
  return $record
}

function Get-HeartbeatAgeSeconds {
  param($Record)
  if (-not $Record -or -not $Record.heartbeatAt) { return [double]::PositiveInfinity }
  try {
    $style = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $heartbeat = [DateTime]::Parse($Record.heartbeatAt, [System.Globalization.CultureInfo]::InvariantCulture, $style)
    return ([DateTime]::UtcNow - $heartbeat).TotalSeconds
  } catch { return [double]::PositiveInfinity }
}

switch ($Action) {
  'Acquire' {
    $lockPath = Get-LockPath
    $queueWait = 0
    $attempt = 0
    while ($true) {
      $lock = Read-Lock
      $now = [DateTime]::UtcNow
      if (-not $lock) {
        try {
          $lockId = [guid]::NewGuid().ToString()
          $record = New-LockRecord -LockId $lockId -AcquiredAt $now -QueueWaitSeconds $queueWait -TakeoverReason $null
          Write-Lock -Record $record -CreateNew
          Write-EnvValue -Key 'SESSION_LOCK_ID' -Value $lockId
          Write-EnvValue -Key 'SESSION_LOCK_GROUP' -Value $Group
          Write-EnvValue -Key 'SESSION_LOCK_PATH' -Value $lockPath
          Write-EnvValue -Key 'SESSION_HEARTBEAT_SECONDS' -Value $HeartbeatSeconds
          Write-OutputValue -Key 'status' -Value 'acquired'
          Write-OutputValue -Key 'lock_id' -Value $lockId
          Write-OutputValue -Key 'queue_wait_seconds' -Value $queueWait
          $lines = @(
            '### Session Lock',
            '',
            "- Status: acquired",
            "- LockId: $lockId",
            "- Group: $Group",
          "- Queue wait (s): $queueWait",
          "- File: $lockPath"
        )
        Write-Summary -Lines $lines
        Write-StatusFile -Lines $lines
        exit 0
        } catch [System.IO.IOException] {
          # file created by another process between read and write; treat as active lock
          $lock = Read-Lock
        }
      }

      $age = Get-HeartbeatAgeSeconds -Record $lock
      if ($age -gt $StaleSeconds) {
        if ($ForceTakeover) {
          $lockId = [guid]::NewGuid().ToString()
          $record = New-LockRecord -LockId $lockId -AcquiredAt $now -QueueWaitSeconds $queueWait -TakeoverReason "stale heartbeat ($([math]::Round($age,2)) s)"
          Write-Lock -Record $record
          Write-EnvValue -Key 'SESSION_LOCK_ID' -Value $lockId
          Write-EnvValue -Key 'SESSION_LOCK_GROUP' -Value $Group
          Write-EnvValue -Key 'SESSION_LOCK_PATH' -Value $lockPath
          Write-EnvValue -Key 'SESSION_HEARTBEAT_SECONDS' -Value $HeartbeatSeconds
          Write-OutputValue -Key 'status' -Value 'takeover'
          Write-OutputValue -Key 'lock_id' -Value $lockId
          Write-OutputValue -Key 'queue_wait_seconds' -Value $queueWait
          $lines = @(
            '### Session Lock',
            '',
            "- Status: takeover",
            "- Reason: stale heartbeat ($([math]::Round($age,2)) s)",
            "- LockId: $lockId",
            "- Group: $Group",
          "- Queue wait (s): $queueWait",
          "- File: $lockPath"
        )
        Write-Summary -Lines $lines
        Write-StatusFile -Lines $lines
        exit 0
        } else {
          Write-OutputValue -Key 'status' -Value 'stale'
          $lines = @(
            '### Session Lock',
            '',
            "- Status: stale-lock-detected",
            "- Age (s): $([math]::Round($age,2))",
          "- Existing LockId: $($lock.lockId)",
          "- Group: $Group",
          "- File: $lockPath"
        )
        Write-Summary -Lines $lines
        Write-StatusFile -Lines $lines
        Write-Host "::error::Session lock is stale (age=$([math]::Round($age,2))s). Set SESSION_FORCE_TAKEOVER=1 to override."
        exit 10
        }
      }

      if ($attempt -ge $QueueMaxAttempts) {
        Write-OutputValue -Key 'status' -Value 'timeout'
        $lines = @(
          '### Session Lock',
          '',
          '- Status: queue-timeout',
          "- Waited (s): $queueWait",
          "- Held by: $($lock.job) (run $($lock.runId))",
          "- File: $lockPath"
        )
        Write-Summary -Lines $lines
        Write-StatusFile -Lines $lines
        Write-Host "::error::Session lock still active after $queueWait seconds; aborting."
        exit 11
      }

      if ($attempt -eq 0) {
        Write-Host "::notice::Session lock held by $($lock.job) (run $($lock.runId)); queueing..."
      }
      Start-Sleep -Seconds $QueueWaitSeconds
      $queueWait += $QueueWaitSeconds
      $attempt++
    }
  }

  'Release' {
    $lock = Read-Lock
    if (-not $lock) {
      Write-OutputValue -Key 'status' -Value 'released'
      Write-Summary -Lines @('### Session Lock','','- Status: no-lock-found','- Group: ' + $Group)
      exit 0
    }
    $expectedLockId = if ($env:SESSION_LOCK_ID) { $env:SESSION_LOCK_ID } else { $null }
    if ($expectedLockId -and $lock.lockId -ne $expectedLockId) {
      Write-Host "::warning::Lock owned by $($lock.lockId); current SESSION_LOCK_ID '$expectedLockId' does not match. Skipping release."
      Write-OutputValue -Key 'status' -Value 'mismatch'
      exit 0
    }
    Remove-Item -LiteralPath (Get-LockPath) -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-StatusPath) -ErrorAction SilentlyContinue
    Write-OutputValue -Key 'status' -Value 'released'
    Write-Summary -Lines @(
      '### Session Lock',
      '',
      '- Status: released',
      "- LockId: $($lock.lockId)",
      "- Group: $Group"
    )
    exit 0
  }

  'Heartbeat' {
    $lockId = $env:SESSION_LOCK_ID
    if (-not $lockId) { exit 0 }
    $lock = Read-Lock
    if (-not $lock) { exit 0 }
    if ($lock.lockId -ne $lockId) { exit 0 }
    $lock.heartbeatAt = [DateTime]::UtcNow.ToString('o')
    Write-Lock -Record $lock
    Write-OutputValue -Key 'status' -Value 'heartbeat'
    exit 0
  }

  'Inspect' {
    $lock = Read-Lock
    if (-not $lock) {
      Write-Host "No active session lock for group '$Group'."
      exit 1
    }
    $age = Get-HeartbeatAgeSeconds -Record $lock
    Write-Host "Group      : $Group"
    if ($lock.PSObject.Properties.Name -contains 'sessionName' -and $lock.sessionName) { Write-Host "Session    : $($lock.sessionName)" }
    Write-Host "LockId     : $($lock.lockId)"
    Write-Host "Owner      : $($lock.workflow)/$($lock.job)"
    Write-Host "Run        : $($lock.runId) (attempt $($lock.runAttempt))"
    Write-Host "Actor      : $($lock.actor)"
    Write-Host "AcquiredAt : $($lock.acquiredAt)"
    Write-Host "Heartbeat  : $($lock.heartbeatAt) (age $([math]::Round($age,2)) s)"
    exit 0
  }
}
