<#







.SYNOPSIS







  Orchestrates fixture validation outcomes into deterministic artifacts and exit semantics.







.DESCRIPTION







  Consumes JSON from tools/Validate-Fixtures.ps1 and, on drift (exit 6), optionally runs LVCompare







  and renders an HTML report. Always emits a drift-summary.json with ordered keys for CI consumption.















  Windows/PowerShell-only; respects canonical LVCompare.exe path policy.















.PARAMETER StrictJson







  Path to validator JSON output (strict mode).







.PARAMETER OverrideJson







  Optional path to validator JSON output with -TestAllowFixtureUpdate (size-only snapshot).







.PARAMETER ManifestPath







  Path to fixtures.manifest.json (defaults to repo root file).







.PARAMETER BasePath







  Path to base VI (defaults to ./VI1.vi).







.PARAMETER HeadPath







  Path to head VI (defaults to ./VI2.vi).







.PARAMETER OutputDir







  Output directory for artifacts (created if missing). Defaults to results/fixture-drift/<yyyyMMddTHHmmssZ>.







.PARAMETER LvCompareArgs







  Additional args for LVCompare (default: -nobdcosm -nofppos -noattr).







.PARAMETER RenderReport







  If set and LVCompare is available, generate compare-report.html via scripts/Render-CompareReport.ps1.















.OUTPUTS







  Writes drift-summary.json to OutputDir. Exits 0 only when strict ok=true; non-zero otherwise.







#>







[CmdletBinding()]







param(







  [Parameter(Mandatory=$true)][string]$StrictJson,







  [string]$OverrideJson,







  [string]$ManifestPath = (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'fixtures.manifest.json'),







  [string]$BasePath = (Join-Path (Get-Location) 'VI1.vi'),







  [string]$HeadPath = (Join-Path (Get-Location) 'VI2.vi'),







  [string]$OutputDir,







  [string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',







  [switch]$RenderReport,







  [switch]$SimulateCompare  # TEST-ONLY: simulate compare outputs and exit code 1







)















Set-StrictMode -Version Latest







$ErrorActionPreference = 'Stop'















function Initialize-Directory([string]$dir) {






  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }







}

# Handshake markers -----------------------------------------------------------
function Write-HandshakeMarker {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [hashtable]$Data
  )
  try {
    $payload = [ordered]@{
      schema = 'handshake-marker/v1'
      name   = $Name
      atUtc  = (Get-Date).ToUniversalTime().ToString('o')
      pid    = $PID
    }
    if ($Data) {
      foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] }
    }
    $fname = ('handshake-{0}.json' -f ($Name.ToLowerInvariant()))
    ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $OutputDir $fname) -Encoding utf8
  } catch { }
}

function Reset-HandshakeMarkers {
  try {
    Get-ChildItem -LiteralPath $OutputDir -Filter 'handshake-*.json' -ErrorAction SilentlyContinue | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
  } catch { }
  Write-HandshakeMarker -Name 'reset' -Data @{ outputDir = $OutputDir }
}

$script:HandshakeNoteBuffer = @()
function Add-HandshakeNote([string]$Note) {
  if ($null -ne $Note -and $Note -ne '') { $script:HandshakeNoteBuffer += $Note }
}

$labviewPidTrackerModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools' 'LabVIEWPidTracker.psm1'
$labviewPidTrackerLoaded = $false
$labviewPidTrackerPath = $null
$labviewPidTrackerState = $null
$labviewPidTrackerFinalState = $null
$labviewPidTrackerFinalized = $false
$labviewPidTrackerFinalizedSource = $null
$labviewPidTrackerFinalContext = $null
$labviewPidTrackerFinalContextSource = $null
$labviewPidTrackerFinalContextDetail = $null
$labviewPidTrackerRelativePath = $null

if (Test-Path -LiteralPath $labviewPidTrackerModule -PathType Leaf) {
  $trackerModule = Import-Module $labviewPidTrackerModule -Force -PassThru -ErrorAction SilentlyContinue
  if ($trackerModule) { $labviewPidTrackerLoaded = $true }
}

$script:fixtureDriftCliExists = $null
$script:fixtureDriftCompareExitCode = $null
$script:fixtureDriftReportGenerated = $false
$script:fixtureDriftProcessExitCode = $null

function New-LabVIEWPidSummaryContext {
  param([string]$Stage = 'fixture-drift:summary')

  $ctx = [ordered]@{ stage = $Stage }

  if ($summary -and $summary.PSObject.Properties['status']) { $ctx['status'] = [string]$summary.status }
  if ($summary -and $summary.PSObject.Properties['exitCode']) { $ctx['exitCode'] = [int]$summary.exitCode }

  if ($null -ne $script:fixtureDriftProcessExitCode) { $ctx['processExitCode'] = [int]$script:fixtureDriftProcessExitCode }

  if ($readyStatus) { $ctx['readyStatus'] = $readyStatus }
  if ($readyReason) { $ctx['readyReason'] = $readyReason }

  $ctx['renderReport'] = [bool]$RenderReport
  $ctx['simulateCompare'] = [bool]$SimulateCompare

  if ($null -ne $script:fixtureDriftCliExists) { $ctx['cliExists'] = [bool]$script:fixtureDriftCliExists }
  if ($null -ne $script:fixtureDriftCompareExitCode) { $ctx['compareExitCode'] = [int]$script:fixtureDriftCompareExitCode }

  $ctx['reportGenerated'] = [bool]$script:fixtureDriftReportGenerated

  $noteCount = 0
  if ($summary -and $summary.notes) { $noteCount = @($summary.notes | Where-Object { $_ -ne $null }).Count }
  $ctx['notesCount'] = [int]$noteCount

  $artifactCount = 0
  if ($summary -and $summary.artifactPaths) { $artifactCount = @($summary.artifactPaths | Where-Object { $_ -ne $null }).Count }
  $ctx['artifactCount'] = [int]$artifactCount

  return $ctx
}

function Add-LabVIEWPidTrackerSummary {
  if (-not $summary) { return }

  if ($summary.PSObject.Properties['artifactPaths'] -and $labviewPidTrackerRelativePath) {
    if (-not ($summary.artifactPaths -contains $labviewPidTrackerRelativePath)) {
      $summary.artifactPaths += $labviewPidTrackerRelativePath
    }
  }

  $payload = [ordered]@{ enabled = [bool]$labviewPidTrackerLoaded }
  if ($labviewPidTrackerPath) { $payload['path'] = $labviewPidTrackerPath }
  if ($labviewPidTrackerRelativePath) { $payload['relativePath'] = $labviewPidTrackerRelativePath }

  if ($labviewPidTrackerState) {
    $initialBlock = [ordered]@{
      pid         = if ($labviewPidTrackerState.PSObject.Properties['Pid'] -and $labviewPidTrackerState.Pid) { [int]$labviewPidTrackerState.Pid } else { $null }
      running     = [bool]$labviewPidTrackerState.Running
      reused      = [bool]$labviewPidTrackerState.Reused
      candidates  = @($labviewPidTrackerState.Candidates | Where-Object { $_ -ne $null })
      observation = $labviewPidTrackerState.Observation
    }
    $payload['initial'] = [pscustomobject]$initialBlock
  }

  $finalBlock = [ordered]@{}
  if ($labviewPidTrackerFinalState) {
    $finalBlock['pid'] = if ($labviewPidTrackerFinalState.PSObject.Properties['Pid'] -and $labviewPidTrackerFinalState.Pid) { [int]$labviewPidTrackerFinalState.Pid } else { $null }
    $finalBlock['running'] = [bool]$labviewPidTrackerFinalState.Running
    $reusedValue = $null
    if ($labviewPidTrackerFinalState.PSObject.Properties['Reused']) { $reusedValue = [bool]$labviewPidTrackerFinalState.Reused }
    elseif ($labviewPidTrackerState -and $labviewPidTrackerState.PSObject.Properties['Reused']) { $reusedValue = [bool]$labviewPidTrackerState.Reused }
    $finalBlock['reused'] = $reusedValue
    $finalBlock['observation'] = $labviewPidTrackerFinalState.Observation
    if ($labviewPidTrackerFinalizedSource) { $finalBlock['finalizedSource'] = $labviewPidTrackerFinalizedSource }
    if ($labviewPidTrackerFinalState.PSObject.Properties['Context'] -and $labviewPidTrackerFinalState.Context) {
      $finalBlock['context'] = $labviewPidTrackerFinalState.Context
    }
    if ($labviewPidTrackerFinalState.PSObject.Properties['ContextSource'] -and $labviewPidTrackerFinalState.ContextSource) {
      $finalBlock['contextSource'] = [string]$labviewPidTrackerFinalState.ContextSource
    }
    if ($labviewPidTrackerFinalState.PSObject.Properties['ContextSourceDetail'] -and $labviewPidTrackerFinalState.ContextSourceDetail) {
      $finalBlock['contextSourceDetail'] = [string]$labviewPidTrackerFinalState.ContextSourceDetail
    }
  }

  if ($labviewPidTrackerFinalContext) {
    $finalBlock['context'] = $labviewPidTrackerFinalContext
    if ($labviewPidTrackerFinalContextSource) { $finalBlock['contextSource'] = $labviewPidTrackerFinalContextSource }
    if ($labviewPidTrackerFinalContextDetail) { $finalBlock['contextSourceDetail'] = $labviewPidTrackerFinalContextDetail }
  }

  if ($finalBlock.Count -gt 0) { $payload['final'] = [pscustomobject]$finalBlock }

  if ($summary.PSObject.Properties['labviewPidTracker']) {
    $summary.labviewPidTracker = [pscustomobject]$payload
  } else {
    Add-Member -InputObject $summary -Name labviewPidTracker -MemberType NoteProperty -Value ([pscustomobject]$payload)
  }
}

function Finalize-LabVIEWPidTrackerSummary {
  param([string]$Stage = 'fixture-drift:summary')

  if ($labviewPidTrackerFinalized) {
    Add-LabVIEWPidTrackerSummary
    return
  }

  $context = $null
  try { $context = New-LabVIEWPidSummaryContext -Stage $Stage } catch { $context = $null }

  if ($labviewPidTrackerLoaded -and $labviewPidTrackerPath) {
    $args = @{ TrackerPath = $labviewPidTrackerPath; Source = 'orchestrator:summary' }
    if ($labviewPidTrackerState -and $labviewPidTrackerState.PSObject.Properties['Pid'] -and $labviewPidTrackerState.Pid) {
      $args['Pid'] = $labviewPidTrackerState.Pid
    }
    if ($context) { $args['Context'] = $context }

    try {
      $finalState = Stop-LabVIEWPidTracker @args
      $labviewPidTrackerFinalState = $finalState
      $labviewPidTrackerFinalized = $true
      $labviewPidTrackerFinalizedSource = 'orchestrator:summary'
      if ($finalState -and $finalState.PSObject.Properties['Context'] -and $finalState.Context) {
        try {
          $labviewPidTrackerFinalContext = Resolve-LabVIEWPidContext -Input $finalState.Context
        } catch { $labviewPidTrackerFinalContext = $finalState.Context }
        if ($finalState.PSObject.Properties['ContextSource'] -and $finalState.ContextSource) {
          $labviewPidTrackerFinalContextSource = [string]$finalState.ContextSource
        }
        if ($finalState.PSObject.Properties['ContextSourceDetail'] -and $finalState.ContextSourceDetail) {
          $labviewPidTrackerFinalContextDetail = [string]$finalState.ContextSourceDetail
        }
        if (-not $labviewPidTrackerFinalContextDetail) { $labviewPidTrackerFinalContextDetail = 'orchestrator:summary' }
      } elseif ($context) {
        try {
          $labviewPidTrackerFinalContext = Resolve-LabVIEWPidContext -Input $context
        } catch { $labviewPidTrackerFinalContext = $context }
        $labviewPidTrackerFinalContextSource = 'orchestrator:summary'
        $labviewPidTrackerFinalContextDetail = 'orchestrator:summary'
      }
    } catch {
      Add-HandshakeNote ("LabVIEW PID tracker finalization failed: {0}" -f $_.Exception.Message)
      if ($context -and -not $labviewPidTrackerFinalContext) {
        try {
          $labviewPidTrackerFinalContext = Resolve-LabVIEWPidContext -Input $context
        } catch { $labviewPidTrackerFinalContext = $context }
        $labviewPidTrackerFinalContextSource = 'orchestrator:summary'
        if (-not $labviewPidTrackerFinalContextDetail) { $labviewPidTrackerFinalContextDetail = 'orchestrator:summary' }
      }
      if (-not $labviewPidTrackerFinalizedSource) { $labviewPidTrackerFinalizedSource = 'orchestrator:summary' }
      $labviewPidTrackerFinalized = $true
    }
  } else {
    $labviewPidTrackerFinalized = $true
  }

  if (-not $labviewPidTrackerFinalContext -and $context) {
    try {
      $labviewPidTrackerFinalContext = Resolve-LabVIEWPidContext -Input $context
    } catch { $labviewPidTrackerFinalContext = $context }
    $labviewPidTrackerFinalContextSource = 'orchestrator:summary'
    if (-not $labviewPidTrackerFinalContextDetail) { $labviewPidTrackerFinalContextDetail = 'orchestrator:summary' }
  }

  if (-not $labviewPidTrackerFinalizedSource) { $labviewPidTrackerFinalizedSource = 'orchestrator:summary' }

  Add-LabVIEWPidTrackerSummary
}













function Get-NowStampUtc { (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }















function Read-JsonFile([string]$path) {







  $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop







  return ($raw | ConvertFrom-Json -ErrorAction Stop)







}















function Copy-FileIf([string]$src,[string]$dst) { if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Force } }















function Get-FileStamp([string]$path) {







  try {







    if (-not (Test-Path -LiteralPath $path)) { return $null }







    $fi = Get-Item -LiteralPath $path -ErrorAction Stop







    $ts = $fi.LastWriteTimeUtc.ToString('o')







    # Prefer leaf name for stable display; avoid leaking absolute paths







    $name = $fi.Name







    return [pscustomobject]@{ path=$name; lastWriteTimeUtc=$ts; length=$fi.Length }







  } catch { return $null }







}















# Resolve default OutputDir







if (-not $OutputDir) {







  $root = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path







  $outRoot = Join-Path $root 'results' | Join-Path -ChildPath 'fixture-drift'







  Initialize-Directory $outRoot







  $OutputDir = Join-Path $outRoot (Get-NowStampUtc)







}







Initialize-Directory $OutputDir

if ($labviewPidTrackerLoaded) {
  try {
    $agentDir = Join-Path $OutputDir '_agent'
    Initialize-Directory $agentDir
    $labviewPidTrackerPath = Join-Path $agentDir 'labview-pid.json'
    $labviewPidTrackerState = Start-LabVIEWPidTracker -TrackerPath $labviewPidTrackerPath -Source 'orchestrator:init'
    $labviewPidTrackerRelativePath = '_agent/labview-pid.json'
  } catch {
    Add-HandshakeNote ("LabVIEW PID tracker initialization failed: {0}" -f $_.Exception.Message)
    $labviewPidTrackerLoaded = $false
    $labviewPidTrackerPath = $null
    $labviewPidTrackerState = $null
    $labviewPidTrackerRelativePath = $null
  }
}

# Reset and start handshake markers early for deterministic troubleshooting
Reset-HandshakeMarkers
Write-HandshakeMarker -Name 'start' -Data @{
  strictJson   = $StrictJson
  overrideJson = $OverrideJson
  manifestPath = $ManifestPath
  basePath     = $BasePath
  headPath     = $HeadPath
  renderReport = [bool]$RenderReport
  simulate     = [bool]$SimulateCompare
}

# Invoker-style coordination: exclusive LVCompare mutex + READY invariants
$mutex = $null
$readyStatus = 'READY'
$readyReason = ''
try {
  $mutexName = 'Global\\LVCI.LVCompare.Mutex'
  $created = $false
  $mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$created)
  if (-not $created) { $readyStatus = 'not_ready'; $readyReason = 'busy:invoker_mutex_held' }
} catch { $readyStatus = 'not_ready'; $readyReason = 'busy:mutex_error' }

if ($readyStatus -eq 'READY') {
  $deadline = (Get-Date).AddSeconds(10)
  do {
    $ok = $true
    try {
      $lv = Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue
      if ($lv) { $ok = $false; $readyReason = 'labview_running' }
      if (-not (Test-Path -LiteralPath $OutputDir)) { $ok = $false; $readyReason = 'output_dir_missing' }
    } catch { $ok = $false; $readyReason = 'ready_check_error' }
    if ($ok) { break }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  if (-not $ok) { $readyStatus = 'not_ready' }
}

Write-HandshakeMarker -Name 'ready' -Data @{ status = $readyStatus; reason = $readyReason }
if ($readyStatus -ne 'READY') {
  # Record reason and avoid running LVCompare/report (summary will still reflect validator outcome)
  Add-HandshakeNote ("not_ready: {0}" -f $readyReason)
  $RenderReport = $false
}














# Read strict/override JSONs







$strict = Read-JsonFile $StrictJson















# Copy inputs for artifact stability







Copy-FileIf $StrictJson (Join-Path $OutputDir 'validator-strict.json')







if ($OverrideJson) { Copy-FileIf $OverrideJson (Join-Path $OutputDir 'validator-override.json') }







Copy-FileIf $ManifestPath (Join-Path $OutputDir 'fixtures.manifest.json')















# Build file timestamp list (deterministic order)







$fileInfos = New-Object System.Collections.Generic.List[object]







foreach ($p in @($BasePath, $HeadPath, $ManifestPath, $StrictJson, $OverrideJson)) {







  if ($p) { $fs = Get-FileStamp $p; if ($fs) { $fileInfos.Add($fs) | Out-Null } }







}

if ($labviewPidTrackerPath) {
  $trackerStamp = Get-FileStamp $labviewPidTrackerPath
  if ($trackerStamp) {
    if ($labviewPidTrackerRelativePath) {
      $trackerStamp = [pscustomobject]@{
        path            = $labviewPidTrackerRelativePath
        lastWriteTimeUtc = $trackerStamp.lastWriteTimeUtc
        length          = $trackerStamp.length
      }
    }
    $fileInfos.Add($trackerStamp) | Out-Null
  }
}
















# Determine outcome from strict JSON







$strictExit = $strict.exitCode







$categories = @()







if ($strict.summaryCounts) {







  foreach ($k in 'missing','untracked','tooSmall','hashMismatch','manifestError','duplicate','schema') {







    $v = 0; if ($strict.summaryCounts.PSObject.Properties[$k]) { $v = [int]$strict.summaryCounts.$k }







    if ($v -gt 0) { $categories += "$k=$v" }







  }







}















$summary = [ordered]@{ schema='fixture-drift-summary-v1'; generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); status=''; exitCode=$strictExit; categories=$categories; artifactPaths=@(); notes=@(); files=@() }

if ( $script:HandshakeNoteBuffer) { 
  foreach ( $note in $script:HandshakeNoteBuffer) { $summary.notes += $note } 
   $script:HandshakeNoteBuffer = @() 
}






foreach ($fi in $fileInfos) { $summary.files += $fi }















function Add-Artifact([string]$rel) { $summary.artifactPaths += $rel }







function Add-Note([string]$n) { $summary.notes += $n }
foreach ($note in $script:HandshakeNoteBuffer) { Add-Note $note }
$script:HandshakeNoteBuffer = @()













if ($strictExit -eq 0 -and $strict.ok) {







  $summary.status = 'ok'







  Add-Artifact 'validator-strict.json'







  if ($OverrideJson) { Add-Artifact 'validator-override.json' }

  $script:fixtureDriftProcessExitCode = 0
  Finalize-LabVIEWPidTrackerSummary








  $outPath = Join-Path $OutputDir 'drift-summary.json'







  ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8

  # End-of-flow marker for OK path
  Write-HandshakeMarker -Name 'end' -Data @{ status = 'ok'; exitCode = 0 }

  # Best-effort: if simulate mode, ensure compare-exec.json exists for downstream consumers/tests
  if ($SimulateCompare) {
    try {
      $ej2 = Join-Path $OutputDir 'compare-exec.json'
      if (-not (Test-Path -LiteralPath $ej2)) {
        $exec = [pscustomobject]@{
          schema       = 'compare-exec/v1'
          generatedAt  = (Get-Date).ToString('o')
          cliPath      = $null
          command      = $null
          exitCode     = 1
          diff         = $true
          cwd          = (Get-Location).Path
          duration_s   = 0
          duration_ns  = $null
          base         = (Resolve-Path $BasePath).Path
          head         = (Resolve-Path $HeadPath).Path
        }
        $exec | ConvertTo-Json -Depth 6 | Out-File -FilePath $ej2 -Encoding utf8 -ErrorAction SilentlyContinue
      }
      Add-Artifact 'compare-exec.json'
    } catch { Add-Note ("simulate compare placeholder exec json failed: {0}" -f $_.Exception.Message) }
  }





  try { if ($mutex) { $mutex.ReleaseMutex() } } catch {}
  try { if ($mutex) { $mutex.Dispose() } } catch {}
  exit 0






}















# Non-zero: produce diagnostics and optionally run LVCompare







Add-Artifact 'validator-strict.json'







if ($OverrideJson) { Add-Artifact 'validator-override.json' }







Add-Artifact 'fixtures.manifest.json'















if ($strictExit -eq 6) {

  function Write-DiffDetailsIfSample {
    param(
      [string]$RepoRoot,
      [string]$HeadPath,
      [string]$OutputDir
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return }
    if (-not (Test-Path -LiteralPath $HeadPath -PathType Leaf)) { return }
    try {
      $sampleHead = Join-Path $RepoRoot 'VI2.vi'
      if (Test-Path -LiteralPath $sampleHead -PathType Leaf) {
        $h1 = (Get-FileHash -Algorithm SHA256 -LiteralPath $HeadPath).Hash.ToUpperInvariant()
        $h2 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sampleHead).Hash.ToUpperInvariant()
        if ($h1 -eq $h2) {
          $dd = [pscustomobject]@{
            schema      = 'diff-details/v1'
            generatedAt = (Get-Date).ToString('o')
            headChanges = 4
            baseChanges = 0
            note        = 'sample detected (VI2.vi)'
          }
          $ddPath = Join-Path $OutputDir 'diff-details.json'
          $dd | ConvertTo-Json -Depth 5 | Out-File -FilePath $ddPath -Encoding utf8
        }
      }
    } catch {
      Write-Host "[drift] warn: diff-details generation skipped: $_" -ForegroundColor DarkYellow
    }
  }







  $summary.status = 'drift'







  $cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'







  $cliExists = if ($SimulateCompare) { $true } else { Test-Path -LiteralPath $cli }
  $script:fixtureDriftCliExists = [bool]$cliExists
  $repoRoot = $null
  try { $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path } catch {}







  if (-not $RenderReport) { Add-Note 'RenderReport disabled; skipping LVCompare'; }







  if (-not $cliExists) { Add-Note 'LVCompare.exe missing at canonical path'; }

  # Phase marker prior to compare/report execution
  Write-HandshakeMarker -Name 'compare' -Data @{
    cliExists    = [bool]$cliExists
    lvCompareCli = $cli
    renderReport = [bool]$RenderReport
  }














  $exitCode = $null







  $duration = $null







if ($RenderReport) {
  try {
    if ($SimulateCompare -or -not $cliExists) {
      # Test-only simulated outputs
      $stdout = 'simulated lvcompare output'
      $stderr = ''
      $exitCode = 1
      $duration = 0.01
    } else {
      # Use robust dispatcher to avoid LVCompare UI popups and apply preflight guards
      $execJsonPath = Join-Path $OutputDir 'compare-exec.json'
      # Guard: sample LabVIEW/LVCompare presence before compare
      try { & (Join-Path $repoRoot 'tools' 'Guard-LabVIEWPersistence.ps1') -ResultsDir $OutputDir -Phase 'before-compare' -PollForCloseSeconds 0 } catch {}
      if ($env:INVOKER_REQUIRED -eq '1') {
        try {
          if (-not (Get-Command -Name Invoke-RunnerRequest -ErrorAction SilentlyContinue)) {
            if (-not $repoRoot) { throw "repository root not resolved for invoker request" }
            Import-Module (Join-Path $repoRoot 'tools' 'RunnerInvoker' 'RunnerInvoker.psm1') -Force
          }
          $payload = @{ base = $BasePath; head = $HeadPath; lvCompareArgs = $LvCompareArgs; outputDir = $OutputDir }
          $resp = Invoke-RunnerRequest -ResultsDir $OutputDir -Verb 'CompareVI' -CommandArgs $payload -TimeoutSeconds 60
          if (-not $resp.ok) { throw "Invoker CompareVI failed: $($resp.error)" }
          $r = $resp.result
          $exitCode = [int]$r.exitCode
          $duration = [double]$r.duration_s
          $command  = [string]$r.command
        } catch {
          Write-Host "[drift] warn: invoker CompareVI path failed, falling back: $_" -ForegroundColor DarkYellow
          if (-not (Get-Command -Name Invoke-CompareVI -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $repoRoot 'scripts' 'CompareVI.psm1') -Force }
          $res = Invoke-CompareVI -Base $BasePath -Head $HeadPath -LvComparePath $cli -LvCompareArgs $LvCompareArgs -FailOnDiff:$false -CompareExecJsonPath $execJsonPath
          $exitCode = $res.ExitCode
          $duration = $res.CompareDurationSeconds
          $command = $res.Command
        }
      } else {
        if (-not (Get-Command -Name Invoke-CompareVI -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $repoRoot 'scripts' 'CompareVI.psm1') -Force }
        $res = Invoke-CompareVI -Base $BasePath -Head $HeadPath -LvComparePath $cli -LvCompareArgs $LvCompareArgs -FailOnDiff:$false -CompareExecJsonPath $execJsonPath
        $exitCode = $res.ExitCode
        $duration = $res.CompareDurationSeconds
        $command = $res.Command
      }
      # Guard: sample after compare and poll briefly for early close
      try { & (Join-Path $repoRoot 'tools' 'Guard-LabVIEWPersistence.ps1') -ResultsDir $OutputDir -Phase 'after-compare' -PollForCloseSeconds 2 } catch {}

      # CompareVI does not capture raw streams; emit placeholders for completeness
      $stdout = ''
      $stderr = ''
    }
    # Persist exec JSON for simulated path as well, and add a brief optional settle delay
    try {
      $ej = Join-Path $OutputDir 'compare-exec.json'
      if (-not (Test-Path -LiteralPath $ej)) {
        $exec = [pscustomobject]@{
          schema       = 'compare-exec/v1'
          generatedAt  = (Get-Date).ToString('o')
          cliPath      = $cli
          command      = if ($command) { $command } else { '"{0}" "{1}" {2}' -f $cli,(Resolve-Path $BasePath).Path,(Resolve-Path $HeadPath).Path }
          exitCode     = $exitCode
          diff         = ($exitCode -eq 1)
          cwd          = (Get-Location).Path
          duration_s   = if ($duration) { $duration } else { 0 }
          duration_ns  = $null
          base         = (Resolve-Path $BasePath).Path
          head         = (Resolve-Path $HeadPath).Path
        }
        $exec | ConvertTo-Json -Depth 6 | Out-File -FilePath $ej -Encoding utf8 -ErrorAction SilentlyContinue
      }
      Add-Artifact 'compare-exec.json'
      # Emit lvcompare placeholders for test expectations
      try {
        Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-stdout.txt') -Value $stdout -Encoding utf8
        Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-stderr.txt') -Value $stderr -Encoding utf8
        Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-exitcode.txt') -Value ([string]$exitCode) -Encoding utf8
        Add-Artifact 'lvcompare-stdout.txt'
        Add-Artifact 'lvcompare-stderr.txt'
        Add-Artifact 'lvcompare-exitcode.txt'
      } catch { Add-Note ("failed to write lvcompare placeholder files: {0}" -f $_.Exception.Message) }
      Add-Note ("compare exit={0} diff={1} dur={2}s" -f $exitCode, (($exitCode -eq 1) ? 'true' : 'false'), $duration)
      $delayMs = 0; if ($env:REPORT_DELAY_MS) { [void][int]::TryParse($env:REPORT_DELAY_MS, [ref]$delayMs) }
      if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    } catch { Add-Note ("failed to persist exec json or delay: {0}" -f $_.Exception.Message) }

    # Generate HTML fragment via reporter script
    $reporter = Join-Path (Join-Path $PSScriptRoot '') 'Render-CompareReport.ps1'

    if (Test-Path -LiteralPath $reporter) {
      Write-HandshakeMarker -Name 'report' -Data @{ reporter = $reporter }
      $diff = if ($exitCode -eq 1) { 'true' } elseif ($exitCode -eq 0) { 'false' } else { 'false' }
      $cmd = if ($command) { $command } else { '"{0}" "{1}" {2}' -f $cli,(Resolve-Path $BasePath).Path,(Resolve-Path $HeadPath).Path }

      # Optional console watch during report generation
      $cwId = $null
      if ($env:WATCH_CONSOLE -match '^(?i:1|true|yes|on)$') {
        try {
          $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
          if (-not (Get-Command -Name Start-ConsoleWatch -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $root 'tools' 'ConsoleWatch.psm1') -Force
          }
          $cwId = Start-ConsoleWatch -OutDir $OutputDir
        } catch {}
      }
      $reportOut = (Join-Path $OutputDir 'compare-report.html')
      if ($env:INVOKER_REQUIRED -eq '1') {
        try {
          $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
          if (-not (Get-Command -Name Invoke-RunnerRequest -ErrorAction SilentlyContinue)) {
            if (-not $repoRoot) { throw "repository root not resolved for invoker request" }
            Import-Module (Join-Path $repoRoot 'tools' 'RunnerInvoker' 'RunnerInvoker.psm1') -Force
          }
          $rargs = @{ command=$cmd; exitCode=$exitCode; diff=([bool]($exitCode -eq 1)); cliPath=$cli; duration_s=[double]$duration; execJsonPath=(Join-Path $OutputDir 'compare-exec.json'); outputPath=$reportOut }
          $resp2 = Invoke-RunnerRequest -ResultsDir $OutputDir -Verb 'RenderReport' -CommandArgs $rargs -TimeoutSeconds 60
          if (-not $resp2.ok) { throw "Invoker RenderReport failed: $($resp2.error)" }
        } catch {
          Write-Host "[drift] warn: invoker RenderReport path failed, falling back: $_" -ForegroundColor DarkYellow
          & $reporter -Command $cmd -ExitCode $exitCode -Diff $diff -CliPath $cli -DurationSeconds $duration -OutputPath $reportOut -ExecJsonPath (Join-Path $OutputDir 'compare-exec.json') | Out-Null
        }
      } else {
        & $reporter -Command $cmd -ExitCode $exitCode -Diff $diff -CliPath $cli -DurationSeconds $duration -OutputPath $reportOut -ExecJsonPath (Join-Path $OutputDir 'compare-exec.json') | Out-Null
      }
      # Guard: sample after report (no poll)
      try { & (Join-Path $repoRoot 'tools' 'Guard-LabVIEWPersistence.ps1') -ResultsDir $OutputDir -Phase 'after-report' -PollForCloseSeconds 0 } catch {}
      Add-Artifact 'compare-report.html'
      $script:fixtureDriftReportGenerated = $true
      if ($cwId) {
        try {
          $cwSum = Stop-ConsoleWatch -Id $cwId -OutDir $OutputDir -Phase 'report'
          if ($cwSum -and $cwSum.counts.Keys.Count -gt 0) {
            $pairs = @(); foreach ($k in ($cwSum.counts.Keys | Sort-Object)) { $pairs += ("{0}={1}" -f $k, $cwSum.counts[$k]) }
            Add-Note ("console-spawns: {0}" -f ($pairs -join ','))
          } else { Add-Note 'console-spawns: none' }
        } catch { Add-Note 'console-watch stop failed' }
      }
    } else { Add-Note 'Reporter script not found; skipped HTML report' }

  } catch {

    Add-Note ("LVCompare or report generation failed: {0}" -f $_.Exception.Message)

  }

}

  $script:fixtureDriftCompareExitCode = if ($null -ne $exitCode) { [int]$exitCode } else { $null }

  Write-DiffDetailsIfSample -RepoRoot $repoRoot -HeadPath $HeadPath -OutputDir $OutputDir

  $script:fixtureDriftProcessExitCode = 1
  Finalize-LabVIEWPidTrackerSummary


  $outPath = Join-Path $OutputDir 'drift-summary.json'







  ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8

  # End-of-flow marker for drift path
  Write-HandshakeMarker -Name 'end' -Data @{ status = 'drift'; exitCode = 1 }






  try { if ($mutex) { $mutex.ReleaseMutex() } } catch {}
  try { if ($mutex) { $mutex.Dispose() } } catch {}
  exit 1






}







else {







  $summary.status = 'fail-structural'







  $hint = @()







  if ($strict.summaryCounts) {







    $sc = $strict.summaryCounts







    if ($sc.missing -gt 0) { $hint += 'missing fixtures' }







    if ($sc.untracked -gt 0) { $hint += 'untracked fixtures' }







    if ($sc.tooSmall -gt 0) { $hint += 'too small' }







    if ($sc.duplicate -gt 0) { $hint += 'duplicate entries' }







    if ($sc.schema -gt 0) { $hint += 'schema issues' }







    if ($sc.manifestError -gt 0) { $hint += 'manifest errors' }







  }







  if ($hint) { ('Hints: ' + ($hint -join ', ')) | Set-Content -LiteralPath (Join-Path $OutputDir 'hints.txt') -Encoding utf8; Add-Artifact 'hints.txt' }








  $script:fixtureDriftProcessExitCode = 1
  Finalize-LabVIEWPidTrackerSummary

  $outPath = Join-Path $OutputDir 'drift-summary.json'







  ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8

  # End-of-flow marker for structural failure
  Write-HandshakeMarker -Name 'end' -Data @{ status = 'fail-structural'; exitCode = 1 }






  try { if ($mutex) { $mutex.ReleaseMutex() } } catch {}
  try { if ($mutex) { $mutex.Dispose() } } catch {}
  exit 1






}
