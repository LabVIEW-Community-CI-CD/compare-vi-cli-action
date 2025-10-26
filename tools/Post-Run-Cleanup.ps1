# Post-run cleanup orchestrator. Aggregates cleanup requests and ensures close
# helpers execute at most once per job via the Once-Guard module.
[CmdletBinding()]
param(
  [switch]$CloseLabVIEW,
  [switch]$CloseLVCompare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path '.').Path
Import-Module (Join-Path $repoRoot 'tools/Once-Guard.psm1') -Force

$logDir = Join-Path $repoRoot 'tests/results/_agent/post'
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$requestsDir = Join-Path $logDir 'requests'
if (-not (Test-Path -LiteralPath $requestsDir)) {
  New-Item -ItemType Directory -Path $requestsDir -Force | Out-Null
}

$logPath = Join-Path $logDir 'post-run-cleanup.log'
function Write-Log {
  param([string]$Message)
  $stamp = (Get-Date).ToUniversalTime().ToString('o')
  ("[{0}] {1}" -f $stamp, $Message) | Out-File -FilePath $logPath -Append -Encoding utf8
}

function Convert-MetadataToHashtable {
  param([object]$Metadata)
  if ($null -eq $Metadata) { return @{} }
  if ($Metadata -is [hashtable]) { return $Metadata }
  $table = @{}
  if ($Metadata -is [System.Management.Automation.PSObject]) {
    foreach ($prop in $Metadata.PSObject.Properties) { $table[$prop.Name] = $prop.Value }
    return $table
  }
  try {
    foreach ($prop in ($Metadata | Get-Member -MemberType NoteProperty)) {
      $name = $prop.Name
      $table[$name] = $Metadata.$name
    }
  } catch {}
  return $table
}

$rawRequests = @()
if (Test-Path -LiteralPath $requestsDir) {
  foreach ($file in Get-ChildItem -LiteralPath $requestsDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try {
      $payload = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 6
      $rawRequests += [pscustomobject]@{
        Name     = $payload.name
        Metadata = $payload.metadata
        Path     = $file.FullName
      }
    } catch {
      Write-Log ("Failed to parse request file {0}: {1}" -f $file.FullName, $_.Exception.Message)
    }
  }
}

function Resolve-RequestMetadata {
  param([string]$Name)
  $match = $rawRequests | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
  if ($match) { return $match.Metadata }
  return $null
}

function Remove-RequestFiles {
  param([string]$Name)
  foreach ($req in $rawRequests | Where-Object { $_.Name -eq $Name }) {
    try { Remove-Item -LiteralPath $req.Path -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Invoke-ForceCloseProcesses {
  param(
    [string[]]$ProcessNames,
    [string]$Label
  )

  $scriptPath = Join-Path $repoRoot 'tools' 'Force-CloseLabVIEW.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Log ("Force-CloseLabVIEW.ps1 not found; skipping {0} fallback." -f $Label)
    return $false
  }

  $processArgs = @()
  if ($ProcessNames -and $ProcessNames.Count -gt 0) {
    $processArgs = @('-ProcessName', $ProcessNames)
  }

  $output = & $scriptPath @processArgs
  $exitCode = $LASTEXITCODE
  if ($output) {
    Write-Log ("Force-CloseLabVIEW output ({0}): {1}" -f $Label, $output)
  }

  Start-Sleep -Milliseconds 300
  $remaining = @()
  foreach ($name in $ProcessNames) {
    try { $remaining += @(Get-Process -Name $name -ErrorAction SilentlyContinue) } catch {}
  }
  if ($exitCode -eq 0 -and $remaining.Count -eq 0) {
    Write-Log ("Force close succeeded for {0}." -f ($ProcessNames -join ','))
    return $true
  }

  if ($remaining.Count -gt 0) {
    $details = $remaining | ForEach-Object { "{0}(PID {1})" -f $_.ProcessName, $_.Id }
    Write-Warning ("Force-CloseLabVIEW unable to terminate {0}: {1}" -f $Label, ($details -join ', '))
  }

  if ($exitCode -ne 0) {
    Write-Warning ("Force-CloseLabVIEW exited with code {0} for {1}." -f $exitCode, $Label)
  }

  return $false
}

Write-Log ("Post-Run-Cleanup invoked. Parameters: CloseLabVIEW={0}, CloseLVCompare={1}" -f $CloseLabVIEW.IsPresent, $CloseLVCompare.IsPresent)
$debugTool = Join-Path $repoRoot 'tools' 'Debug-ChildProcesses.ps1'
$preSnapshot = $null
try { $preSnapshot = & $debugTool -ResultsDir 'tests/results' -AppendStepSummary } catch { Write-Log ("Pre-clean snapshot failed: {0}" -f $_.Exception.Message) }

$labVIEWRequested = $CloseLabVIEW.IsPresent -or ($rawRequests | Where-Object { $_.Name -eq 'close-labview' })
$lvCompareRequested = $CloseLVCompare.IsPresent -or ($rawRequests | Where-Object { $_.Name -eq 'close-lvcompare' })

function Invoke-CloseLabVIEW {
  param($Metadata)
  $Metadata = Convert-MetadataToHashtable $Metadata
  $scriptPath = Join-Path $repoRoot 'tools' 'Close-LabVIEW.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Log "Close-LabVIEW.ps1 not found; skipping."
    return
  }
  $params = @{}
  if ($Metadata) {
    if ($Metadata.ContainsKey('version') -and $Metadata.version) { $params.MinimumSupportedLVVersion = $Metadata.version }
    if ($Metadata.ContainsKey('bitness') -and $Metadata.bitness) { $params.SupportedBitness = $Metadata.bitness }
  }
  $markerPath = Join-Path $logDir 'once-close-labview.marker'
  if (Test-Path -LiteralPath $markerPath) {
    Write-Log 'Close-LabVIEW already executed; skipping duplicate.'
    return
  }
  $action = {
    param($scriptPath,$params)
    & $scriptPath @params
    $exit = $LASTEXITCODE
    $exit
  }.GetNewClosure()
  $attempt = 0
  $maxAttempts = 3
  while ($attempt -lt $maxAttempts) {
    $attempt++
    $exitCode = & $action $scriptPath $params
    if ($exitCode -ne 0) {
      Write-Warning ("Close-LabVIEW.ps1 exited with code {0} (attempt {1}/{2})." -f $exitCode,$attempt,$maxAttempts)
    }
    Start-Sleep -Milliseconds 300
    $stillRunning = @()
    try { $stillRunning = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue) } catch {}
    if ($exitCode -eq 0 -and $stillRunning.Count -eq 0) {
      $executed = Invoke-Once -Key 'close-labview' -Action { } -ScopeDirectory $logDir
      if ($executed) { Write-Log "Close-LabVIEW executed successfully." }
      return
    }
    if ($stillRunning.Count -gt 0) {
      Write-Warning ("Close-LabVIEW.ps1 completed but LabVIEW.exe still running (PID(s): {0})" -f ($stillRunning.Id -join ','))
    }
  if ($attempt -lt $maxAttempts) {
    Write-Log ("Close-LabVIEW retry scheduled ({0}/{1})." -f ($attempt + 1), $maxAttempts)
    Start-Sleep -Seconds 1
  }
}
  Write-Log "Close-LabVIEW helper retries exhausted; invoking force-close fallback."
  if (Invoke-ForceCloseProcesses -ProcessNames @('LabVIEW') -Label 'LabVIEW') {
    $executed = Invoke-Once -Key 'close-labview' -Action { } -ScopeDirectory $logDir
    if ($executed) { Write-Log "Close-LabVIEW force-close executed successfully." }
    return
  }
  throw "Close-LabVIEW.ps1 failed to terminate LabVIEW.exe after $maxAttempts attempt(s)."
}

function Invoke-CloseLVCompare {
  param($Metadata)
  $Metadata = Convert-MetadataToHashtable $Metadata
  $scriptPath = Join-Path $repoRoot 'tools' 'Close-LVCompare.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Log "Close-LVCompare.ps1 not found; skipping."
    return
  }
  $params = @{}
  if ($Metadata) {
    foreach ($key in @('base','head','BaseVi','HeadVi')) {
      if ($Metadata.ContainsKey($key) -and $Metadata[$key]) {
        if ($key -match 'base') { $params.BaseVi = $Metadata[$key] }
        if ($key -match 'head') { $params.HeadVi = $Metadata[$key] }
      }
    }
    if ($Metadata.ContainsKey('labviewExe') -and $Metadata.labviewExe) { $params.LabVIEWExePath = $Metadata.labviewExe }
    if ($Metadata.ContainsKey('version') -and $Metadata.version) { $params.MinimumSupportedLVVersion = $Metadata.version }
    if ($Metadata.ContainsKey('bitness') -and $Metadata.bitness) { $params.SupportedBitness = $Metadata.bitness }
  }
  $action = {
    param($scriptPath,$params)
    & $scriptPath @params
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
      throw "Close-LVCompare.ps1 exited with code $exit."
    }
  }.GetNewClosure()
  $markerPath = Join-Path $logDir 'once-close-lvcompare.marker'
  if (Test-Path -LiteralPath $markerPath) {
    Write-Log 'Close-LVCompare already executed; skipping duplicate.'
    return
  }
  $attempt = 0
  $maxAttempts = 3
  while ($attempt -lt $maxAttempts) {
    $attempt++
    try {
      & $action $scriptPath $params
    } catch {
      Write-Warning ("Close-LVCompare.ps1 exited with error (attempt {0}/{1}): {2}" -f $attempt,$maxAttempts,$_.Exception.Message)
    }
    Start-Sleep -Milliseconds 300
    $remaining = @()
    try { $remaining = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue) } catch {}
    if ($remaining.Count -eq 0) {
      $executed = Invoke-Once -Key 'close-lvcompare' -Action { } -ScopeDirectory $logDir
      if ($executed) { Write-Log "Close-LVCompare executed successfully." }
      return
    }
    Write-Warning ("Close-LVCompare.ps1 completed but LVCompare.exe still running (PID(s): {0})" -f ($remaining.Id -join ','))
  if ($attempt -lt $maxAttempts) {
    Write-Log ("Close-LVCompare retry scheduled ({0}/{1})." -f ($attempt + 1), $maxAttempts)
    Start-Sleep -Seconds 1
  }
}
  Write-Log "Close-LVCompare helper retries exhausted; invoking force-close fallback."
  if (Invoke-ForceCloseProcesses -ProcessNames @('LVCompare') -Label 'LVCompare') {
    $executed = Invoke-Once -Key 'close-lvcompare' -Action { } -ScopeDirectory $logDir
    if ($executed) { Write-Log "Close-LVCompare force-close executed successfully." }
    return
  }
  throw "Close-LVCompare.ps1 failed to terminate LVCompare.exe after $maxAttempts attempt(s)."
}

try {
  if ($labVIEWRequested) {
    $metadata = Resolve-RequestMetadata 'close-labview'
    Invoke-CloseLabVIEW -Metadata $metadata
    Remove-RequestFiles 'close-labview'
  } else {
    Write-Log 'No LabVIEW close requested.'
  }

  if ($lvCompareRequested) {
    $metadata = Resolve-RequestMetadata 'close-lvcompare'
    Invoke-CloseLVCompare -Metadata $metadata
    Remove-RequestFiles 'close-lvcompare'
  } else {
    Write-Log 'No LVCompare close requested.'
  }
} catch {
  Write-Log ("Post-Run-Cleanup encountered an error: {0}" -f $_.Exception.Message)
  throw
}

 $postSnapshot = $null
try { $postSnapshot = & $debugTool -ResultsDir 'tests/results' -AppendStepSummary } catch { Write-Log ("Post-clean snapshot failed: {0}" -f $_.Exception.Message) }
if ($postSnapshot -and $postSnapshot.groups) {
  $maxPwsh = 1
  try {
    if ($env:MAX_ALLOWED_PWSH) { $maxPwsh = [int]$env:MAX_ALLOWED_PWSH }
  } catch {}
  foreach ($groupName in $postSnapshot.groups.Keys) {
    $group = $postSnapshot.groups[$groupName]
    if ($group.count -gt 0) {
      $preCount = 0
      if ($preSnapshot -and $preSnapshot.groups -and $preSnapshot.groups.ContainsKey($groupName)) {
        $preCount = $preSnapshot.groups[$groupName].count
      }
      $message = "Post-clean residual processes detected for '$groupName': count=$($group.count), wsMB={0:N1}, pmMB={1:N1}" -f (($group.memory.ws)/1MB), (($group.memory.pm)/1MB)
      Write-Log $message
      $shouldWarn = $true
      if ($groupName -ieq 'pwsh' -and $group.count -le $maxPwsh) { $shouldWarn = $false }
      if ($shouldWarn) { Write-Warning $message } else { Write-Host $message -ForegroundColor DarkGray }
      if ($group.count -gt $preCount) {
        Write-Warning ("Process count increased for '{0}' during cleanup (pre={1}, post={2})." -f $groupName,$preCount,$group.count)
      }
    }
  }
}

Write-Host 'Post-Run-Cleanup completed.' -ForegroundColor DarkGray

