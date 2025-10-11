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
  $action = {
    param($scriptPath,$params)
    & $scriptPath @params
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
      throw "Close-LabVIEW.ps1 exited with code $exit."
    }
  }.GetNewClosure()
  $executed = Invoke-Once -Key 'close-labview' -Action { & $action $scriptPath $params } -ScopeDirectory $logDir
  if ($executed) {
    Write-Log "Close-LabVIEW executed successfully."
  } else {
    Write-Log 'Close-LabVIEW already executed; skipping duplicate.'
  }
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
  $executed = Invoke-Once -Key 'close-lvcompare' -Action { & $action $scriptPath $params } -ScopeDirectory $logDir
  if ($executed) {
    Write-Log "Close-LVCompare executed successfully."
  } else {
    Write-Log 'Close-LVCompare already executed; skipping duplicate.'
  }
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

