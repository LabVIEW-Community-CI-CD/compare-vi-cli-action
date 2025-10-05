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



foreach ($fi in $fileInfos) { $summary.files += $fi }







function Add-Artifact([string]$rel) { $summary.artifactPaths += $rel }



function Add-Note([string]$n) { $summary.notes += $n }







if ($strictExit -eq 0 -and $strict.ok) {



  $summary.status = 'ok'



  Add-Artifact 'validator-strict.json'



  if ($OverrideJson) { Add-Artifact 'validator-override.json' }



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



  exit 0



}







# Non-zero: produce diagnostics and optionally run LVCompare



Add-Artifact 'validator-strict.json'



if ($OverrideJson) { Add-Artifact 'validator-override.json' }



Add-Artifact 'fixtures.manifest.json'







if ($strictExit -eq 6) {



  $summary.status = 'drift'



  $cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'



  $cliExists = if ($SimulateCompare) { $true } else { Test-Path -LiteralPath $cli }



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
      $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
      if (-not (Get-Command -Name Invoke-CompareVI -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $repoRoot 'scripts' 'CompareVI.psm1') -Force
      }
      $execJsonPath = Join-Path $OutputDir 'compare-exec.json'
      $res = Invoke-CompareVI -Base $BasePath -Head $HeadPath -LvComparePath $cli -LvCompareArgs $LvCompareArgs -FailOnDiff:$false -CompareExecJsonPath $execJsonPath
      $exitCode = $res.ExitCode
      $duration = $res.CompareDurationSeconds
      $command = $res.Command
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
      & $reporter -Command $cmd -ExitCode $exitCode -Diff $diff -CliPath $cli -DurationSeconds $duration -OutputPath (Join-Path $OutputDir 'compare-report.html') -ExecJsonPath (Join-Path $OutputDir 'compare-exec.json') | Out-Null
      Add-Artifact 'compare-report.html'
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
  $outPath = Join-Path $OutputDir 'drift-summary.json'



  ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8

  # End-of-flow marker for drift path
  Write-HandshakeMarker -Name 'end' -Data @{ status = 'drift'; exitCode = 1 }



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



  $outPath = Join-Path $OutputDir 'drift-summary.json'



  ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $outPath -Encoding utf8

  # End-of-flow marker for structural failure
  Write-HandshakeMarker -Name 'end' -Data @{ status = 'fail-structural'; exitCode = 1 }



  exit 1



}





