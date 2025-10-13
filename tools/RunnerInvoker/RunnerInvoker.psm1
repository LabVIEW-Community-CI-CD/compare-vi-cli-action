Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonFile([string]$Path, [object]$Obj) {
  $dir = Split-Path -Path $Path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = $null
  try {
    $json = $Obj | ConvertTo-Json -Depth 8
  } catch {
    throw "Write-JsonFile ConvertTo-Json failed: $($_.Exception.Message)"
  }
  try {
    $json | Set-Content -LiteralPath $Path -Encoding UTF8
  } catch {
    throw "Write-JsonFile Set-Content failed: $($_.Exception.Message)"
  }
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

function Get-SingleCompareGateEnabled {
  $raw = $env:LVCI_SINGLE_COMPARE
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  $text = $raw.Trim()
  if ($text -eq '') { return $false }
  switch -Regex ($text) {
    '^(?i:false|no|off)$' { return $false }
    '^(?i:true|yes|on)$'  { return $true }
  }
  try {
    if ([int]$text -eq 0) { return $false }
    return $true
  } catch {
    return $true
  }
}

function Get-SingleCompareAutoStopEnabled {
  $raw = $env:LVCI_SINGLE_COMPARE_AUTOSTOP
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  $text = $raw.Trim()
  if ($text -eq '') { return $false }
  switch -Regex ($text) {
    '^(?i:false|no|off)$' { return $false }
    '^(?i:true|yes|on|stop|auto)$'  { return $true }
  }
  try {
    if ([int]$text -eq 0) { return $false }
    return $true
  } catch {
    return $true
  }
}

function Get-SingleCompareState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 6) } catch { return $null }
}

function Set-SingleCompareState([string]$Path, [hashtable]$Metadata) {
  try {
    $dir = Split-Path -Parent -LiteralPath $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload = [pscustomobject]@{
      schema   = 'single-compare-state/v1'
      handled  = $true
      since    = (Get-Date).ToUniversalTime().ToString('o')
      metadata = $Metadata
    }
    $payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $Path -Encoding utf8
  } catch {}
}

function Handle-CompareVI([hashtable]$Args, [string]$ResultsDir) {
  Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'CompareVI.psm1') -Force
  $hasKey = { param($ht,$key) ($ht -is [hashtable]) -and $ht.ContainsKey($key) }
  if (-not (& $hasKey $Args 'base')) { throw "CompareVI requires 'base' argument" }
  if (-not (& $hasKey $Args 'head')) { throw "CompareVI requires 'head' argument" }
  $base = [string]$Args['base']
  $head = [string]$Args['head']
  $cliArgs = if (& $hasKey $Args 'lvCompareArgs') { $Args['lvCompareArgs'] } else { $null }
  $outDir = if (& $hasKey $Args 'outputDir' -and $Args['outputDir']) { [string]$Args['outputDir'] } else { (Join-Path $ResultsDir '_invoker') }
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
  if (-not $Args.outputPath) {
    $Args.outputPath = Join-Path (Join-Path $ResultsDir '_staging/compare') 'compare-report.html'
  }
  $outPath = [string]$Args.outputPath
  $outDir = Split-Path -Parent $outPath
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  $cmd     = [string]$Args.command
  $code    = [int]$Args.exitCode
  $diff    = [bool]$Args.diff
  $cli     = [string]$Args.cliPath
  $dur     = if ($Args.duration_s) { [double]$Args.duration_s } else { 0 }
  $execJson= [string]$Args.execJsonPath
  & $renderer -Command $cmd -ExitCode $code -Diff $diff -CliPath $cli -DurationSeconds $dur -OutputPath $outPath -ExecJsonPath $execJson | Out-Null
  return [pscustomobject]@{ outputPath = $outPath }
}

function Invoke-RunnerRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [Parameter(Mandatory)][ValidateSet('Ping','PhaseDone','CompareVI','RenderReport')][string]$Verb,
    [hashtable]$CommandArgs,
    [int]$TimeoutSeconds = 30
  )

  if (-not $CommandArgs) { $CommandArgs = @{} }
  $baseDir = Join-Path $ResultsDir '_invoker'
  $reqDir  = Join-Path $baseDir 'requests'
  $rspDir  = Join-Path $baseDir 'responses'
  foreach ($d in @($baseDir,$reqDir,$rspDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }

  $id = [guid]::NewGuid().ToString()
  $reqPath = Join-Path $reqDir ("$id.json")
  $rspPath = Join-Path $rspDir ("$id.json")
  $payload = [pscustomobject]@{ id = $id; verb = $Verb; args = $CommandArgs }
  Write-JsonFile -Path $reqPath -Obj $payload

  $deadline = (Get-Date).AddSeconds([math]::Max(1,$TimeoutSeconds))
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $rspPath) {
      $resp = $null
      try { $resp = Read-JsonFile -Path $rspPath } catch {}
      if ($null -eq $resp) { Start-Sleep -Milliseconds 50; continue }
      try { Remove-Item -LiteralPath $rspPath -Force -ErrorAction SilentlyContinue } catch {}
      return $resp
    }
    Start-Sleep -Milliseconds 200
  }
  throw "invoker response timeout for verb '$Verb' id '$id'"
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
  $reqLog = Join-Path $baseDir 'requests-log.ndjson'
  if (-not (Test-Path -LiteralPath $reqLog)) { New-Item -ItemType File -Path $reqLog -Force | Out-Null }
  $singleStatePath = Join-Path $baseDir 'single-compare-state.json'

  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  $lastSpawn = 0
  while ($true) {
    if ($SentinelPath -and -not (Test-Path -LiteralPath $SentinelPath)) { break }

    if (($stopwatch.ElapsedMilliseconds - $lastSpawn) -ge 1000) { Append-Spawns -OutPath $spawns; $lastSpawn = $stopwatch.ElapsedMilliseconds }

    $reqs = Get-ChildItem -LiteralPath $reqDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($f in $reqs) {
      $reqPath = $f.FullName
      $req = Read-JsonFile -Path $reqPath
      $id = [string]$req.id
      $verb = [string]$req.verb
      $reqArgs = @{}
      if ($req.args) {
        if ($req.args -is [System.Collections.IDictionary]) {
          foreach ($key in @($req.args.Keys)) { $reqArgs[$key] = $req.args[$key] }
        } else {
          foreach ($prop in $req.args.PSObject.Properties) { $reqArgs[$prop.Name] = $prop.Value }
        }
      }
      $rspPath = Join-Path $rspDir ("{0}.json" -f $id)
      $handled = $false
      try {
        try {
          $recvEntry = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='received' } | ConvertTo-Json -Compress
          Add-Content -LiteralPath $reqLog -Value $recvEntry -Encoding UTF8
        } catch {}
        $result = $null
        switch ($verb) {
          'Ping' {
            $result = [pscustomobject]@{ pong = $PipeName; at=(Get-Date).ToUniversalTime().ToString('o') }
          }
          'CompareVI' {
            $hashtableArgs = $reqArgs -is [hashtable]
            $previewRequested = $false
            if ($hashtableArgs -and $reqArgs.ContainsKey('preview')) {
              try { $previewRequested = [bool]$reqArgs['preview'] } catch { $previewRequested = $false }
            }
            $outDir = if ($hashtableArgs -and $reqArgs.ContainsKey('outputDir') -and $reqArgs['outputDir']) { [string]$reqArgs['outputDir'] } else { (Join-Path $ResultsDir '_invoker') }
            $gateEnabled = Get-SingleCompareGateEnabled
            $autoStopEnabled = Get-SingleCompareAutoStopEnabled
            $existingState = $null
            if ($gateEnabled) { $existingState = Get-SingleCompareState -Path $singleStatePath }
            $execPath = Join-Path $outDir 'compare-exec.json'
            if ($gateEnabled -and $existingState -and $existingState.handled) {
              try {
                $gateEntry = @{
                  at     = (Get-Date).ToUniversalTime().ToString('o')
                  verb   = $verb
                  stage  = 'gate_block'
                  reason = 'compare_already_handled'
                } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $gateEntry -Encoding UTF8
              } catch {}
              throw ([InvalidOperationException]::new("compare_already_handled: single compare gate active (state=$singleStatePath)"))
            }
            if ($previewRequested) {
              try {
                $logEntry = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='dispatch_preview' } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $logEntry -Encoding UTF8
              } catch {}
              if (-not $hashtableArgs -or -not $reqArgs.ContainsKey('base')) { throw "preview base path not provided" }
              if (-not $hashtableArgs -or -not $reqArgs.ContainsKey('head')) { throw "preview head path not provided" }
              $basePath = [string]$reqArgs['base']
              $headPath = [string]$reqArgs['head']
              if ([string]::IsNullOrWhiteSpace($basePath) -or -not (Test-Path -LiteralPath $basePath)) { throw "preview base path not found: $basePath" }
              if ([string]::IsNullOrWhiteSpace($headPath) -or -not (Test-Path -LiteralPath $headPath)) { throw "preview head path not found: $headPath" }
              $resolvedCli = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
              $resolvedBase = (Resolve-Path -LiteralPath $basePath).Path
              $resolvedHead = (Resolve-Path -LiteralPath $headPath).Path
              $command = '"{0}" "{1}" "{2}"' -f $resolvedCli,($resolvedBase -replace '"','\"'),($resolvedHead -replace '"','\"')
              if ($hashtableArgs -and $reqArgs.ContainsKey('lvCompareArgs') -and $reqArgs['lvCompareArgs']) { $command = $command + ' ' + [string]$reqArgs['lvCompareArgs'] }
              if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
              if ($gateEnabled -and -not $existingState -and (Test-Path -LiteralPath $execPath)) {
                try {
                  $gateEntryPreview = @{
                    at     = (Get-Date).ToUniversalTime().ToString('o')
                    verb   = $verb
                    stage  = 'gate_block'
                    reason = 'compare_already_handled'
                  } | ConvertTo-Json -Compress
                  Add-Content -LiteralPath $reqLog -Value $gateEntryPreview -Encoding UTF8
                } catch {}
                throw ([InvalidOperationException]::new("compare_already_handled: single compare gate active (exec=$execPath)"))
              }
              $exec = [pscustomobject]@{
                schema       = 'compare-exec/v1'
                generatedAt  = (Get-Date).ToString('o')
                cliPath      = $resolvedCli
                command      = $command
                args         = @()
                exitCode     = 1
                diff         = $true
                cwd          = (Get-Location).Path
                duration_s   = 0
                duration_ns  = 0
                base         = $resolvedBase
                head         = $resolvedHead
              }
              $exec | ConvertTo-Json -Depth 6 | Out-File -FilePath $execPath -Encoding utf8
              $result = [pscustomobject]@{
                exitCode = 1
                diff     = $true
                cliPath  = $resolvedCli
                command  = $command
                duration_s  = 0
                duration_ns = 0
                execJsonPath = $execPath
              }
              try {
                $readyEntryPreview = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='result_ready' } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $readyEntryPreview -Encoding UTF8
              } catch {}
              $previewResponse = @{ ok = $true; id = $id; verb = $verb; result = $result }
              try {
                $writeEntryPreview = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='response_write'; path=$rspPath } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $writeEntryPreview -Encoding UTF8
              } catch {}
              try {
                Write-JsonFile -Path $rspPath -Obj $previewResponse
              } catch {
                try {
                  $writeFailEntry = @{
                    at     = (Get-Date).ToUniversalTime().ToString('o')
                    verb   = $verb
                    stage  = 'response_write_error'
                    error  = $_.ToString()
                  } | ConvertTo-Json -Compress
                  Add-Content -LiteralPath $reqLog -Value $writeFailEntry -Encoding UTF8
                } catch {}
                throw
              }
              try {
                $meta = @{
                  preview   = $true
                  outputDir = $outDir
                  base      = $resolvedBase
                  head      = $resolvedHead
                  execPath  = $execPath
                }
                Set-SingleCompareState -Path $singleStatePath -Metadata $meta
              } catch {}
              try {
                $completedPreview = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; ok=$true; stage='completed' } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $completedPreview -Encoding UTF8
              } catch {}
              if ($gateEnabled -and $autoStopEnabled -and $SentinelPath) {
                try {
                  $autoNote = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='auto_stop'; reason='single_compare_complete'; preview=$true } | ConvertTo-Json -Compress
                  Add-Content -LiteralPath $reqLog -Value $autoNote -Encoding UTF8
                } catch {}
                try { Remove-Item -LiteralPath $SentinelPath -Force } catch {}
                try {
                  $autoFile = Join-Path $baseDir 'single-compare-autostop.json'
                  $autoObj = [pscustomobject]@{ schema='invoker-autostop/v1'; preview=$true; at=(Get-Date).ToUniversalTime().ToString('o') }
                  $autoObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $autoFile -Encoding utf8
                } catch {}
              }
              $handled = $true
              continue
            }
            if ($gateEnabled -and -not $existingState -and (Test-Path -LiteralPath $execPath)) {
              try {
                $gateEntryPending = @{
                  at     = (Get-Date).ToUniversalTime().ToString('o')
                  verb   = $verb
                  stage  = 'gate_block'
                  reason = 'compare_already_handled'
                } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $gateEntryPending -Encoding UTF8
              } catch {}
              throw ([InvalidOperationException]::new("compare_already_handled: single compare gate active (exec=$execPath)"))
            }
            $result = Handle-CompareVI -Args $reqArgs -ResultsDir $ResultsDir
            try {
              $metaRun = @{
                preview   = $false
                outputDir = $outDir
                execPath  = $execPath
              }
              Set-SingleCompareState -Path $singleStatePath -Metadata $metaRun
            } catch {}
            try {
              $readyEntryRun = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='result_ready' } | ConvertTo-Json -Compress
              Add-Content -LiteralPath $reqLog -Value $readyEntryRun -Encoding UTF8
            } catch {}
            try {
              $writeEntryRun = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='response_write'; path=$rspPath } | ConvertTo-Json -Compress
              Add-Content -LiteralPath $reqLog -Value $writeEntryRun -Encoding UTF8
            } catch {}
            try {
              Write-JsonFile -Path $rspPath -Obj @{ ok=$true; id=$id; verb=$verb; result=$result }
            } catch {
              try {
                $writeFailRun = @{
                  at     = (Get-Date).ToUniversalTime().ToString('o')
                  verb   = $verb
                  stage  = 'response_write_error'
                  error  = $_.ToString()
                } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $writeFailRun -Encoding UTF8
              } catch {}
              throw
            }
            try {
              $completedRun = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; ok=$true; stage='completed' } | ConvertTo-Json -Compress
              Add-Content -LiteralPath $reqLog -Value $completedRun -Encoding UTF8
            } catch {}
            if ($gateEnabled -and $autoStopEnabled -and $SentinelPath) {
              try {
                $autoNote2 = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='auto_stop'; reason='single_compare_complete'; preview=$false } | ConvertTo-Json -Compress
                Add-Content -LiteralPath $reqLog -Value $autoNote2 -Encoding UTF8
              } catch {}
              try { Remove-Item -LiteralPath $SentinelPath -Force } catch {}
              try {
                $autoFile2 = Join-Path $baseDir 'single-compare-autostop.json'
                $autoObj2 = [pscustomobject]@{ schema='invoker-autostop/v1'; preview=$false; at=(Get-Date).ToUniversalTime().ToString('o') }
                $autoObj2 | ConvertTo-Json -Depth 4 | Out-File -FilePath $autoFile2 -Encoding utf8
              } catch {}
            }
            $handled = $true
          }
          'RenderReport'  { $result = Handle-RenderReport -Args $reqArgs -ResultsDir $ResultsDir }
          'PhaseDone'     {
            $result = [pscustomobject]@{ done = $true }
            if ($SentinelPath) { try { Remove-Item -LiteralPath $SentinelPath -Force } catch {} }
          }
          default { throw "unknown verb: $verb" }
        }
        if ($handled) { continue }
        try {
          $readyEntry = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; stage='result_ready' } | ConvertTo-Json -Compress
          Add-Content -LiteralPath $reqLog -Value $readyEntry -Encoding UTF8
        } catch {}
        Write-JsonFile -Path $rspPath -Obj @{ ok=$true; id=$id; verb=$verb; result=$result }
        try {
          $completedEntry = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; ok=$true; stage='completed' } | ConvertTo-Json -Compress
          Add-Content -LiteralPath $reqLog -Value $completedEntry -Encoding UTF8
        } catch {}
      } catch {
        Write-JsonFile -Path $rspPath -Obj @{ ok=$false; id=$id; verb=$verb; error=($_.ToString()) }
        try {
          $failedEntry = @{ at=(Get-Date).ToUniversalTime().ToString('o'); verb=$verb; ok=$false; stage='failed'; error=$_.ToString() } | ConvertTo-Json -Compress
          Add-Content -LiteralPath $reqLog -Value $failedEntry -Encoding UTF8
        } catch {}
      } finally {
        try { Remove-Item -LiteralPath $reqPath -Force } catch {}
      }
    }
    Start-Sleep -Milliseconds $PollIntervalMs
  }
}
Export-ModuleMember -Function Start-InvokerLoop,Invoke-RunnerRequest
