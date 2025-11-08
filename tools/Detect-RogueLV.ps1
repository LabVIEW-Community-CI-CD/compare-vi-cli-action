param(
  [string]$ResultsDir = 'tests/results',
  [int]$LookBackSeconds = 900,
  [switch]$FailOnRogue,
  [switch]$AppendToStepSummary,
  [switch]$Quiet,
  [int]$RetryCount = 1,
  [int]$RetryDelaySeconds = 5,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$retryCount = [Math]::Max(1, [Math]::Abs([int]$RetryCount))
$retryDelay = [Math]::Max(0, [Math]::Abs([int]$RetryDelaySeconds))

$noticeDir = if ($env:LV_NOTICE_DIR) { $env:LV_NOTICE_DIR } else { Join-Path $ResultsDir '_lvcompare_notice' }
$now = Get-Date
$cutoff = $now.AddSeconds(-[math]::Abs($LookBackSeconds))

$noticedLC = New-Object System.Collections.Generic.HashSet[int]
$noticedLV = New-Object System.Collections.Generic.HashSet[int]

if (Test-Path -LiteralPath $noticeDir) {
  $files = Get-ChildItem -Path $noticeDir -Filter 'notice-*.json' | Where-Object { $_.LastWriteTime -ge $cutoff } | Sort-Object LastWriteTime
  foreach($f in $files){
    try {
      $j = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($j.phase -eq 'post-start' -and $j.PSObject.Properties['pid']) {
        [void]$noticedLC.Add([int]$j.pid)
      }
      if ($j.phase -eq 'post-complete' -and $j.PSObject.Properties['labviewPids']){
        foreach($procId in $j.labviewPids){ try { [void]$noticedLV.Add([int]$procId) } catch {} }
      }
    } catch {}
  }
}

function Diff-Rogue([int[]]$live, $noticedSet){
  $rogue = @()
  foreach($procId in $live){ if (-not $noticedSet.Contains([int]$procId)) { $rogue += [int]$procId } }
  return ,$rogue
}

function Get-ProcessDetails {
  param(
    [int[]]$ProcessIds
  )
  $details = @()
  foreach ($processId in $ProcessIds) {
    if ($processId -le 0) { continue }
    try {
      $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
      $creationDate = $null
      $creationDateRaw = $null
      $creationDateError = $null
      if ($proc.CreationDate) {
        $creationDateRaw = $proc.CreationDate
        try {
          $creationDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate).ToString('o')
        } catch {
          $creationDateError = $_.Exception.Message
        }
      }

      $details += [pscustomobject]@{
        pid = $processId
        name = $proc.Name
        commandLine = $proc.CommandLine
        executablePath = $proc.ExecutablePath
        creationDate = $creationDate
        creationDateRaw = $creationDateRaw
        creationDateError = $creationDateError
        error = $null
      }
    } catch {
      $details += [pscustomobject]@{
        pid = $processId
        name = $null
        commandLine = $null
        executablePath = $null
        creationDate = $null
        creationDateRaw = $null
        creationDateError = $null
        error = $_.Exception.Message
      }
    }
  }
  return $details
}

$attemptHistory = @()
$finalAttemptIndex = 0
$finalGeneratedAt = $now
$finalLiveLC = @()
$finalLiveLV = @()
$finalRogueLC = @()
$finalRogueLV = @()

for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
  $attemptTimestamp = Get-Date

  $liveLC = @()
  $liveLV = @()
  try { $liveLC = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  try { $liveLV = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}

  $rogueLC = Diff-Rogue $liveLC $noticedLC
  $rogueLV = Diff-Rogue $liveLV $noticedLV

  $attemptHistory += [ordered]@{
    attempt = $attempt
    generatedAt = $attemptTimestamp.ToString('o')
    live = [ordered]@{
      lvcompare = @($liveLC)
      labview = @($liveLV)
    }
    rogue = [ordered]@{
      lvcompare = @($rogueLC)
      labview = @($rogueLV)
    }
  }

  $finalAttemptIndex = $attempt
  $finalGeneratedAt = $attemptTimestamp
  $finalLiveLC = @($liveLC)
  $finalLiveLV = @($liveLV)
  $finalRogueLC = @($rogueLC)
  $finalRogueLV = @($rogueLV)

  $liveLabelLC = if ($liveLC.Count -gt 0) { $liveLC -join ',' } else { '(none)' }
  $liveLabelLV = if ($liveLV.Count -gt 0) { $liveLV -join ',' } else { '(none)' }
  $rogueLabelLC = if ($rogueLC.Count -gt 0) { $rogueLC -join ',' } else { '(none)' }
  $rogueLabelLV = if ($rogueLV.Count -gt 0) { $rogueLV -join ',' } else { '(none)' }

  $hasRogue = ($rogueLC.Count -gt 0 -or $rogueLV.Count -gt 0)

  if (-not $Quiet -and $retryCount -gt 1) {
    Write-Host ("[Detect-RogueLV] Attempt {0}/{1}: live LVCompare={2} LabVIEW={3} rogue LVCompare={4} LabVIEW={5}" -f $attempt, $retryCount, $liveLabelLC, $liveLabelLV, $rogueLabelLC, $rogueLabelLV) -ForegroundColor DarkGray
    if ($hasRogue -and $attempt -lt $retryCount) {
      if ($retryDelay -gt 0) {
        Write-Warning ("[Detect-RogueLV] Rogue processes detected (attempt {0}/{1}); waiting {2}s before retry." -f $attempt, $retryCount, $retryDelay)
      } else {
        Write-Warning ("[Detect-RogueLV] Rogue processes detected (attempt {0}/{1}); retrying immediately." -f $attempt, $retryCount)
      }
    }
  }

  if (-not $hasRogue) { break }
  if ($attempt -lt $retryCount -and $retryDelay -gt 0) {
    Start-Sleep -Seconds $retryDelay
  }
}

if ($finalAttemptIndex -eq 0) {
  $finalAttemptIndex = 1
  $finalGeneratedAt = Get-Date
}

$finalLiveDetails = [ordered]@{
  lvcompare = @(Get-ProcessDetails -ProcessIds $finalLiveLC)
  labview   = @(Get-ProcessDetails -ProcessIds $finalLiveLV)
}

$out = [ordered]@{
  schema = 'rogue-lv-detection/v1'
  generatedAt = $finalGeneratedAt.ToString('o')
  lookbackSeconds = $LookBackSeconds
  noticeDir = $noticeDir
  live = [ordered]@{ lvcompare = $finalLiveLC; labview = $finalLiveLV }
  liveDetails = $finalLiveDetails
  noticed = [ordered]@{ lvcompare = @($noticedLC); labview = @($noticedLV) }
  rogue = [ordered]@{ lvcompare = $finalRogueLC; labview = $finalRogueLV }
  attempt = [ordered]@{
    index = $finalAttemptIndex
    total = $retryCount
  }
}

if ($attemptHistory.Count -gt 0) {
  $out['attempts'] = $attemptHistory
}

if (-not $Quiet) {
  $lines = @('### Rogue LV Detection','')
  if ($retryCount -gt 1) {
    $lines += ('- Attempt: {0}/{1}' -f $finalAttemptIndex, $retryCount)
  }
  $lines += ('- Lookback: {0}s' -f $LookBackSeconds)
  $lines += ('- Live: LVCompare={0} LabVIEW={1}' -f ($finalLiveLC -join ','), ($finalLiveLV -join ','))
  $lines += ('- Noticed: LVCompare={0} LabVIEW={1}' -f ((@($noticedLC)) -join ','), ((@($noticedLV)) -join ',')) 
  $lines += ('- Rogue: LVCompare={0} LabVIEW={1}' -f ($finalRogueLC -join ','), ($finalRogueLV -join ','))
  if ($out.liveDetails.lvcompare.Count -gt 0 -or $out.liveDetails.labview.Count -gt 0) {
    $lines += ''
    if ($out.liveDetails.lvcompare.Count -gt 0) {
      $lines += '  Live LVCompare details:'
      foreach ($entry in $out.liveDetails.lvcompare) {
        $infoParts = @()
        if ($entry.PSObject.Properties['commandLine'] -and $entry.commandLine) {
          $infoParts += "cmd=$($entry.commandLine)"
        } elseif ($entry.PSObject.Properties['executablePath'] -and $entry.executablePath) {
          $infoParts += "path=$($entry.executablePath)"
        }
        if ($entry.PSObject.Properties['creationDate'] -and $entry.creationDate) {
          $infoParts += "start=$($entry.creationDate)"
        } elseif ($entry.PSObject.Properties['creationDateRaw'] -and $entry.creationDateRaw) {
          $infoParts += "startRaw=$($entry.creationDateRaw)"
        }
        if ($entry.PSObject.Properties['creationDateError'] -and $entry.creationDateError) {
          $infoParts += "startError=$($entry.creationDateError)"
        }
        if ($entry.PSObject.Properties['error'] -and $entry.error) {
          $infoParts += "error=$($entry.error)"
        }
        if (-not $infoParts) { $infoParts = @('(no data)') }
        $lines += ('  - PID {0}: {1}' -f $entry.pid, ($infoParts -join '; '))
      }
    }
    if ($out.liveDetails.labview.Count -gt 0) {
      $lines += '  Live LabVIEW details:'
      foreach ($entry in $out.liveDetails.labview) {
        $infoParts = @()
        if ($entry.PSObject.Properties['commandLine'] -and $entry.commandLine) {
          $infoParts += "cmd=$($entry.commandLine)"
        } elseif ($entry.PSObject.Properties['executablePath'] -and $entry.executablePath) {
          $infoParts += "path=$($entry.executablePath)"
        }
        if ($entry.PSObject.Properties['creationDate'] -and $entry.creationDate) {
          $infoParts += "start=$($entry.creationDate)"
        } elseif ($entry.PSObject.Properties['creationDateRaw'] -and $entry.creationDateRaw) {
          $infoParts += "startRaw=$($entry.creationDateRaw)"
        }
        if ($entry.PSObject.Properties['creationDateError'] -and $entry.creationDateError) {
          $infoParts += "startError=$($entry.creationDateError)"
        }
        if ($entry.PSObject.Properties['error'] -and $entry.error) {
          $infoParts += "error=$($entry.error)"
        }
        if (-not $infoParts) { $infoParts = @('(no data)') }
        $lines += ('  - PID {0}: {1}' -f $entry.pid, ($infoParts -join '; '))
      }
    }
  }
  $txt = $lines -join [Environment]::NewLine
  Write-Host $txt
  if ($AppendToStepSummary -and $env:GITHUB_STEP_SUMMARY) {
    $skipSummary = $false
    if ($env:DISABLE_STEP_SUMMARY -and ($env:DISABLE_STEP_SUMMARY -is [string])) {
      if ($env:DISABLE_STEP_SUMMARY -match '^(?i)(1|true|yes|on)$') { $skipSummary = $true }
    }
    if ($skipSummary) {
      Write-Host 'Rogue LV summary append skipped: DisableStepSummary requested.' -ForegroundColor DarkYellow
    } else {
      $txt | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
}

$json = $out | ConvertTo-Json -Depth 6
if ($OutputPath) {
  try {
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    $json | Out-File -FilePath $OutputPath -Encoding utf8
  } catch {
    Write-Warning ("Failed to write rogue detection payload to '{0}': {1}" -f $OutputPath, $_.Exception.Message)
  }
}
Write-Output $json

if ($FailOnRogue -and ($finalRogueLC.Count -gt 0 -or $finalRogueLV.Count -gt 0)) { exit 3 } else { exit 0 }
