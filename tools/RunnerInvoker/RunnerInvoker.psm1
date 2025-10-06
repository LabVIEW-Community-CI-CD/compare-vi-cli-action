Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonFile([string]$Path, [object]$Obj) {
  $dir = Split-Path -Parent -LiteralPath $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $Obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "json not found: $Path" }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if (-not $raw) { return $null }
  return ($raw | ConvertFrom-Json -Depth 10)
}

function Append-Spawns([string]$OutPath) {
  try {
    $stamp = (Get-Date).ToUniversalTime().ToString('o')
    # Temporarily exclude node.exe from tracking to avoid conflating with runner internals
    $names = @('pwsh','conhost','LabVIEW','LVCompare')
    $entry = [ordered]@{ at=$stamp }
    foreach ($n in $names) {
      try { $ps = @(Get-Process -Name $n -ErrorAction SilentlyContinue) } catch { $ps = @() }
      $entry[$n] = [ordered]@{ count = $ps.Count; pids = @($ps | Select-Object -ExpandProperty Id) }
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $OutPath -Encoding UTF8
  } catch {}
}

function Handle-CompareVI([hashtable]$Args, [string]$ResultsDir) {
  Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'CompareVI.psm1') -Force
  $base = [string]$Args.base
  $head = [string]$Args.head
  $cliArgs = $Args.lvCompareArgs
  $outDir = if ($Args.outputDir) { [string]$Args.outputDir } else { (Join-Path $ResultsDir '_invoker') }
  $execPath = Join-Path $outDir 'compare-exec.json'
  $persistPath = Join-Path $outDir 'compare-persistence.json'
  $beforeLV  = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
  $beforeLVC = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue)
  $res = Invoke-CompareVI -Base $base -Head $head -LvCompareArgs $cliArgs -FailOnDiff:$false -CompareExecJsonPath $execPath
  $afterLV  = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
  $afterLVC = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue)
  try {
    $payload = @()
    if (Test-Path -LiteralPath $persistPath) { try { $payload = Get-Content -LiteralPath $persistPath -Raw | ConvertFrom-Json -Depth 6 } catch { $payload = @() } }
    if ($payload -isnot [System.Collections.IList]) { $payload = @() }
    $payload += [pscustomobject]@{
      schema='compare-persistence/v1'
      at=(Get-Date).ToUniversalTime().ToString('o')
      before=[ordered]@{ labview=@($beforeLV | Select-Object -ExpandProperty Id); lvcompare=@($beforeLVC | Select-Object -ExpandProperty Id) }
      after =[ordered]@{ labview=@($afterLV  | Select-Object -ExpandProperty Id); lvcompare=@($afterLVC  | Select-Object -ExpandProperty Id) }
    }
    $payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $persistPath -Encoding utf8
  } catch {}
  return [pscustomobject]@{
    exitCode = [int]$res.ExitCode
    diff     = [bool]$res.Diff
    cliPath  = [string]$res.CliPath
    command  = [string]$res.Command
    duration_s  = [double]$res.CompareDurationSeconds
    duration_ns = [long]$res.CompareDurationNanoseconds
    execJsonPath = $execPath
  }
}

function Handle-RenderReport([hashtable]$Args, [string]$ResultsDir) {
  $renderer = Join-Path (Join-Path $PSScriptRoot '..' '..') 'scripts/Render-CompareReport.ps1'
  $outPath = if ($Args.outputPath) { [string]$Args.outputPath } else { (Join-Path $ResultsDir 'compare-report.html') }
  $cmd     = [string]$Args.command
  $code    = [int]$Args.exitCode
  $diff    = [bool]$Args.diff
  $cli     = [string]$Args.cliPath
  $dur     = if ($Args.duration_s) { [double]$Args.duration_s } else { 0 }
  $execJson= [string]$Args.execJsonPath
  & $renderer -Command $cmd -ExitCode $code -Diff $diff -CliPath $cli -DurationSeconds $dur -OutputPath $outPath -ExecJsonPath $execJson | Out-Null
  return [pscustomobject]@{ outputPath = $outPath }
}

function Start-InvokerLoop {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$PipeName,
    [Parameter()][string]$SentinelPath,
    [Parameter()][string]$ResultsDir = 'tests/results/_invoker',
    [int]$PollIntervalMs = 200
  )

  $baseDir = Join-Path $ResultsDir '_invoker'
  $reqDir = Join-Path $baseDir 'requests'
  $rspDir = Join-Path $baseDir 'responses'
  foreach ($d in @($baseDir,$reqDir,$rspDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
  $spawns = Join-Path $baseDir 'console-spawns.ndjson'
  if (-not (Test-Path -LiteralPath $spawns)) { New-Item -ItemType File -Path $spawns -Force | Out-Null }

  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  $lastSpawn = 0
  while ($true) {
    if ($SentinelPath -and -not (Test-Path -LiteralPath $SentinelPath)) { break }

    # Periodic spawns snapshot (1s cadence)
    if (($stopwatch.ElapsedMilliseconds - $lastSpawn) -ge 1000) { Append-Spawns -OutPath $spawns; $lastSpawn = $stopwatch.ElapsedMilliseconds }

    $reqs = Get-ChildItem -LiteralPath $reqDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($f in $reqs) {
      $reqPath = $f.FullName
      $req = Read-JsonFile -Path $reqPath
      $id = [string]$req.id
      $verb = [string]$req.verb
      $args = @{}; if ($req.args) { $args = @{} + $req.args.PSObject.Properties | ForEach-Object { @{ ($_.Name) = $_.Value } } | ForEach-Object { $_ } }
      $rspPath = Join-Path $rspDir ("$id.json")
      try {
        $result = $null
        switch ($verb) {
          'Ping'          { $result = [pscustomobject]@{ pong = $PipeName; at=(Get-Date).ToUniversalTime().ToString('o') } }
          'CompareVI'     { $result = Handle-CompareVI -Args $args -ResultsDir $ResultsDir }
          'RenderReport'  { $result = Handle-RenderReport -Args $args -ResultsDir $ResultsDir }
          'PhaseDone'     { $result = [pscustomobject]@{ done = $true } ; if ($SentinelPath) { try { Remove-Item -LiteralPath $SentinelPath -Force } catch {} } }
          default         { throw "unknown verb: $verb" }
        }
        Write-JsonFile -Path $rspPath -Obj @{ ok=$true; id=$id; verb=$verb; result=$result }
      } catch {
        Write-JsonFile -Path $rspPath -Obj @{ ok=$false; id=$id; verb=$verb; error=($_.ToString()) }
      } finally {
        try { Remove-Item -LiteralPath $reqPath -Force } catch {}
      }
    }
    Start-Sleep -Milliseconds $PollIntervalMs
  }
}

Export-ModuleMember -Function Start-InvokerLoop
