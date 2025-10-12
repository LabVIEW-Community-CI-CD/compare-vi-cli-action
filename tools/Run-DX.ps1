[CmdletBinding()]
param(
  [ValidateSet('Pester','TestStand')]
  [string]$Suite = 'Pester',

  # Shared / Pester parameters
  [string]$ResultsPath = 'tests/results',
  [switch]$IncludeIntegration,
  [string[]]$IncludePatterns,
  [double]$TimeoutMinutes = 0,
  [double]$TimeoutSeconds = 0,
  [switch]$ContinueOnTimeout,

  # TestStand parameters
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$LabVIEWExePath,
  [string]$LVComparePath,
  [string]$OutputRoot = 'tests/results/teststand-session',
  [string[]]$Flags,
  [switch]$ReplaceFlags,
  [ValidateSet('detect','spawn')]
  [string]$Warmup = 'detect',
  [switch]$RenderReport,
  [switch]$CloseLabVIEW,
  [switch]$CloseLVCompare,
  [switch]$OpenReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ResultsDir([string]$path){
  try {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  } catch {}
}

function Resolve-PathSafe([string]$path){
  try {
    return (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
  } catch {
    return $path
  }
}

function Write-DxLine([string]$msg,[string]$kind='info'){
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  Write-Host ("[dx] {0} {1}" -f $kind,$msg)
}

# Apply DX toggles
if (-not $env:DX_CONSOLE_LEVEL)   { $env:DX_CONSOLE_LEVEL   = 'concise' }
if (-not $env:DX_CONSOLE_PREFERRED) { $env:DX_CONSOLE_PREFERRED = '1' }
$env:LV_SUPPRESS_UI       = '1'
$env:LV_NO_ACTIVATE       = '1'
$env:LV_CURSOR_RESTORE    = '1'
if (-not $env:LV_IDLE_WAIT_SECONDS)     { $env:LV_IDLE_WAIT_SECONDS = '2' }
if (-not $env:LV_IDLE_MAX_WAIT_SECONDS) { $env:LV_IDLE_MAX_WAIT_SECONDS = '5' }

New-ResultsDir -path $ResultsPath

Write-DxLine "dx-start suite=$Suite results=$ResultsPath"

# Pre snapshot
try { & (Join-Path $PSScriptRoot 'Debug-ChildProcesses.ps1') -ResultsDir $ResultsPath | Out-Null } catch {}

# Flag active processes pre-run (LVCompare, LabVIEW, g-cli, VIPM)
try {
  $pre = @{}
  try { $pre.lvcompare = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -Expand Id) } catch {}
  try { $pre.labview   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -Expand Id) } catch {}
  try { $pre.gcli      = @(Get-CimInstance Win32_Process -Filter "Name='g-cli.exe'" -ErrorAction SilentlyContinue | Select-Object -Expand ProcessId) } catch {}
  try { $pre.vipm      = @(Get-Process -Name 'VIPM' -ErrorAction SilentlyContinue | Select-Object -Expand Id) } catch { try { $pre.vipm = @(Get-CimInstance Win32_Process -Filter "Name='VIPM.exe'" -ErrorAction SilentlyContinue | Select-Object -Expand ProcessId) } catch {} }
  $cnt = (($pre.lvcompare|Measure-Object).Count + ($pre.labview|Measure-Object).Count + ($pre.gcli|Measure-Object).Count + ($pre.vipm|Measure-Object).Count)
  if ($cnt -gt 0) {
    Write-DxLine ("procs pre lvcompare={0} labview={1} gcli={2} vipm={3}" -f ($pre.lvcompare -join ','), ($pre.labview -join ','), ($pre.gcli -join ','), ($pre.vipm -join ',')) 'warn'
  }
} catch {}

$exit = 1
$statusEnvelope = $null
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if ($Suite -eq 'TestStand') {
  if ([string]::IsNullOrWhiteSpace($BaseVi) -or [string]::IsNullOrWhiteSpace($HeadVi)) {
    throw "Suite=TestStand requires -BaseVi and -HeadVi"
  }

$harness = Join-Path $repoRoot 'tools/TestStand-CompareHarness.ps1'
  if (-not (Test-Path -LiteralPath $harness -PathType Leaf)) { throw "TestStand harness not found at $harness" }

  # Resolve output root relative to repo
  if (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot $OutputRoot
  }

  $hParams = @{ BaseVi = $BaseVi; HeadVi = $HeadVi; OutputRoot = $OutputRoot; Warmup = $Warmup }
  if ($LabVIEWExePath) { $hParams.LabVIEWExePath = $LabVIEWExePath }
  if ($LVComparePath)  { $hParams.LVComparePath  = $LVComparePath }
  if ($PSBoundParameters.ContainsKey('Flags')) { $hParams.Flags = $Flags }
  if ($ReplaceFlags)   { $hParams.ReplaceFlags = $true }
  if ($RenderReport)   { $hParams.RenderReport   = $true }
  if ($CloseLabVIEW)   { $hParams.CloseLabVIEW   = $true }
  if ($CloseLVCompare) { $hParams.CloseLVCompare = $true }

  try {
    & $harness @hParams
    $exit = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 0 }
  } catch {
    Write-Error $_
    $exit = 1
  }

  $sessionIndex = Join-Path $OutputRoot 'session-index.json'
  $session = $null
  if (Test-Path -LiteralPath $sessionIndex -PathType Leaf) {
    try { $session = Get-Content -LiteralPath $sessionIndex -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
  }

  $sessionIndexResolved = if (Test-Path -LiteralPath $sessionIndex -PathType Leaf) { Resolve-PathSafe $sessionIndex } else { $null }
  $resultsResolved = Resolve-PathSafe $ResultsPath
  # Attempt to enrich with lvcompare capture details if present
  $capResolved = $null
  $capJson = $null
  try {
    $capCandidate = $null
    if ($session -and $session.compare -and $session.compare.capture) { $capCandidate = $session.compare.capture }
    if ($capCandidate -and (Test-Path -LiteralPath $capCandidate -PathType Leaf)) {
      $capResolved = Resolve-PathSafe $capCandidate
      try { $capJson = Get-Content -LiteralPath $capCandidate -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
  } catch {}
  $statusEnvelope = [ordered]@{
    schema       = 'dx-status-teststand/v1'
    at           = (Get-Date).ToUniversalTime().ToString('o')
    resultsDir   = $resultsResolved
    outputRoot   = $OutputRoot
    base         = $BaseVi
    head         = $HeadVi
    labviewExe   = $LabVIEWExePath
    lvcompareExe = $LVComparePath
    exitCode     = $exit
    success      = ($exit -eq 0)
    sessionIndex = $sessionIndexResolved
  }
  if ($session) {
    try {
      $statusEnvelope.session = @{
        outcome  = $session.outcome
        error    = $session.error
        compare  = $session.compare
        content  = $session.content
      }
    } catch {}
  }
  if ($capJson) {
    try {
      $statusEnvelope.lvcompare = [ordered]@{
        exitCode = [int]$capJson.exitCode
        seconds  = [double]$capJson.seconds
        command  = $capJson.command
        args     = $capJson.args
        capture  = $capResolved
      }
      $diffVal = $false
      try { if ($session -and $session.outcome -and $null -ne $session.outcome.diff) { $diffVal = [bool]$session.outcome.diff } else { $diffVal = ([int]$capJson.exitCode -eq 1) } } catch {}
      Write-DxLine ("compare exit={0} diff={1} seconds={2} capture={3}" -f $capJson.exitCode, $diffVal, $capJson.seconds, ($capResolved ?? 'n/a'))
      # Emit command and cliPath if present in session
      $cmdShort = $null
      try { if ($capJson.command) { $cmdShort = ($capJson.command -replace '\s+', ' ').Trim() } } catch {}
      if ($cmdShort) { Write-DxLine ("compare cmd={0}" -f $cmdShort) }
      $cliPathFromSession = $null
      try { if ($session -and $session.compare -and $session.compare.cliPath) { $cliPathFromSession = $session.compare.cliPath } } catch {}
      if ($cliPathFromSession) { Write-DxLine ("compare cli={0}" -f $cliPathFromSession) }
    } catch {}
  }
  elseif ($OutputRoot) {
    # Fallback to compare-exec.json when capture is missing
    try {
      $execPathFallback = Join-Path (Join-Path $OutputRoot 'compare') 'compare-exec.json'
      if (Test-Path -LiteralPath $execPathFallback -PathType Leaf) {
        $execJson = Get-Content -LiteralPath $execPathFallback -Raw | ConvertFrom-Json -ErrorAction Stop
        $statusEnvelope.lvcompare = [ordered]@{
          exitCode = [int]$execJson.exitCode
          seconds  = [double]($execJson.duration_s)
          command  = $execJson.command
          cliPath  = $execJson.cliPath
          execJson = (Resolve-PathSafe $execPathFallback)
        }
        $diffVal = [bool]$execJson.diff
        Write-DxLine ("compare(exit={0} diff={1} sec={2}) execJson={3}" -f $execJson.exitCode, $diffVal, $execJson.duration_s, (Resolve-PathSafe $execPathFallback))
        $cmdShort2 = ($execJson.command -replace '\s+', ' ').Trim()
        if ($cmdShort2) { Write-DxLine ("compare cmd={0}" -f $cmdShort2) }
        if ($execJson.cliPath) { Write-DxLine ("compare cli={0}" -f $execJson.cliPath) }
      }
    } catch {}
  }

  # Content-diff enrichment: print and record when content differs but CLI reports no diff
  try {
    $contentDiffVal = $false
    if ($session -and $session.content -and $session.content.expectDiff -ne $null) {
      $contentDiffVal = [bool]$session.content.expectDiff
    }
    $cliDiffVal = $false
    try { if ($statusEnvelope.lvcompare -and $statusEnvelope.lvcompare.exitCode -ne $null) { $cliDiffVal = ([int]$statusEnvelope.lvcompare.exitCode -eq 1) } } catch {}
    if ($contentDiffVal -and -not $cliDiffVal) {
      Write-DxLine 'compare contentDiff=True cliDiff=False' 'warn'
      if (-not $statusEnvelope.lvcompare) { $statusEnvelope.lvcompare = @{} }
      $statusEnvelope.lvcompare.contentDiff = $true
    }
  } catch {}
} else {
  # Pester suite
  $console = if ($env:DX_CONSOLE_LEVEL -and -not [string]::IsNullOrWhiteSpace($env:DX_CONSOLE_LEVEL)) { $env:DX_CONSOLE_LEVEL } else { 'concise' }
  $paramTable = @{ ResultsPath = $ResultsPath; IncludeIntegration = $IncludeIntegration.IsPresent; ConsoleLevel = $console; LiveOutput = $true }
  if ($IncludePatterns -and $IncludePatterns.Count -gt 0) { $paramTable.IncludePatterns = $IncludePatterns }
  if ($TimeoutSeconds -gt 0) { $paramTable.TimeoutSeconds = [double]$TimeoutSeconds }
  elseif ($TimeoutMinutes -gt 0) { $paramTable.TimeoutMinutes = [double]$TimeoutMinutes }
  if ($ContinueOnTimeout) { $paramTable.ContinueOnTimeout = $true }

  try {
    & (Join-Path $repoRoot 'Invoke-PesterTests.ps1') @paramTable
    $exit = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 0 }
  } catch {
    Write-Error $_
    $exit = 1
  }

  $summaryPath = Join-Path $ResultsPath 'pester-summary.json'
  $summary = $null
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    try { $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
  }
  $summaryResolved = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { Resolve-PathSafe $summaryPath } else { $null }
  $resultsResolved = Resolve-PathSafe $ResultsPath
  $statusEnvelope = [ordered]@{
    schema            = 'dx-status-pester/v1'
    at                = (Get-Date).ToUniversalTime().ToString('o')
    resultsDir        = $resultsResolved
    includeIntegration= $IncludeIntegration.IsPresent
    includePatterns   = $IncludePatterns
    exitCode          = $exit
    success           = ($exit -eq 0)
    summaryPath       = $summaryResolved
  }
  if ($summary) {
    try {
      $statusEnvelope.summary = @{ result = $summary.result; totals = $summary.totals }
    } catch {}
  }
}

# Post snapshot
try { & (Join-Path $PSScriptRoot 'Debug-ChildProcesses.ps1') -ResultsDir $ResultsPath | Out-Null } catch {}

# Attempt rogue scan (best-effort)
try { & (Join-Path $PSScriptRoot 'Detect-RogueLV.ps1') -ResultsDir $ResultsPath -AppendToStepSummary | Out-Null } catch {}

# Optional: open report after TestStand run if available
if ($Suite -eq 'TestStand') {
  try {
    $rep = $null
    if ($session -and $session.compare -and $session.compare.reportPath) { $rep = $session.compare.reportPath }
    if (-not $rep -and $OutputRoot) {
      $stagingDir = Join-Path (Join-Path $OutputRoot 'compare') '_staging'
      $rep = Join-Path (Join-Path $stagingDir 'compare') 'compare-report.html'
    }
    if ($rep -and (Test-Path -LiteralPath $rep -PathType Leaf)) {
      Write-DxLine ("report path={0}" -f $rep)
      # Open report automatically when running locally via task
      if ($PSBoundParameters.ContainsKey('OpenReport') -and $OpenReport) {
        try { Invoke-Item -LiteralPath $rep } catch {}
      } elseif ($env:DX_OPEN_REPORT -eq '1') {
        try { Invoke-Item -LiteralPath $rep } catch {}
      }
    }
  } catch {}
}

# Flag active processes post-run (LVCompare, LabVIEW, g-cli, VIPM)
try {
  $post = @{}
  try { $post.lvcompare = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -Expand Id) } catch {}
  try { $post.labview   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -Expand Id) } catch {}
  try { $post.gcli      = @(Get-CimInstance Win32_Process -Filter "Name='g-cli.exe'" -ErrorAction SilentlyContinue | Select-Object -Expand ProcessId) } catch {}
  try { $post.vipm      = @(Get-Process -Name 'VIPM' -ErrorAction SilentlyContinue | Select-Object -Expand Id) } catch { try { $post.vipm = @(Get-CimInstance Win32_Process -Filter "Name='VIPM.exe'" -ErrorAction SilentlyContinue | Select-Object -Expand ProcessId) } catch {} }
  $cnt2 = (($post.lvcompare|Measure-Object).Count + ($post.labview|Measure-Object).Count + ($post.gcli|Measure-Object).Count + ($post.vipm|Measure-Object).Count)
  if ($cnt2 -gt 0) {
    Write-DxLine ("procs post lvcompare={0} labview={1} gcli={2} vipm={3}" -f ($post.lvcompare -join ','), ($post.labview -join ','), ($post.gcli -join ','), ($post.vipm -join ',')) 'warn'
  }
} catch {}

# Emit dx-status (with processes and processWarn)
try {
  $agentDir = Join-Path $ResultsPath '_agent'
  New-ResultsDir -path $agentDir
  $statusPath = Join-Path $agentDir 'dx-status.json'
  if ($null -eq $statusEnvelope) { $statusEnvelope = [ordered]@{ schema='dx-status/v1'; at=(Get-Date).ToUniversalTime().ToString('o'); resultsDir=(Resolve-PathSafe $ResultsPath) } }
  try {
    $procInfo = [ordered]@{
      pre  = @{ lvcompare = @($pre.lvcompare); labview = @($pre.labview); gcli = @($pre.gcli); vipm = @($pre.vipm) }
      post = @{ lvcompare = @($post.lvcompare); labview = @($post.labview); gcli = @($post.gcli); vipm = @($post.vipm) }
    }
    $preCount  = ((@($pre.lvcompare)|Measure-Object).Count + (@($pre.labview)|Measure-Object).Count + (@($pre.gcli)|Measure-Object).Count + (@($pre.vipm)|Measure-Object).Count)
    $postCount = ((@($post.lvcompare)|Measure-Object).Count + (@($post.labview)|Measure-Object).Count + (@($post.gcli)|Measure-Object).Count + (@($post.vipm)|Measure-Object).Count)
    $statusEnvelope.processes = $procInfo
    $statusEnvelope.processWarn = ($postCount -gt 0)
  } catch {}
  ($statusEnvelope | ConvertTo-Json -Depth 8) | Out-File -FilePath $statusPath -Encoding utf8
  Write-DxLine ("dx-complete suite={0} ok={1} exit={2}" -f $Suite, ($exit -eq 0), $exit)
} catch { Write-DxLine ("dx-status error: {0}" -f $_.Exception.Message) 'error' }

exit $exit
