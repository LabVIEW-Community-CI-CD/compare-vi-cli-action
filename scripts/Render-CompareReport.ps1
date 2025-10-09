param(
  [Parameter(Mandatory=$true)] [string]$Command,
  [Parameter(Mandatory=$true)] [int]$ExitCode,
  [Parameter(Mandatory=$true)] [string]$Diff, # 'true'|'false'
  [Parameter(Mandatory=$true)] [string]$CliPath,
  [string]$Base,
  [string]$Head,
  [string]$OutputPath,
  [double]$DurationSeconds,
  [string]$ExecJsonPath
)

$ErrorActionPreference = 'Stop'

# Import shared tokenization pattern
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force

# Render Meta: capture start timestamp and pre-run process snapshot
$renderStart = Get-Date
$preLVCompare = @(); $preLabVIEW = @()
try { $preLVCompare = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
try { $preLabVIEW   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}

# Prefer compare-exec.json when available to avoid relying on transient process state
try {
  $candidatePath = $null
  if (-not $ExecJsonPath -and $OutputPath) {
    $candidatePath = Join-Path (Split-Path -Parent $OutputPath) 'compare-exec.json'
  } elseif ($ExecJsonPath) {
    $candidatePath = $ExecJsonPath
  }
  $source = 'params'
  if ($candidatePath -and (Test-Path -LiteralPath $candidatePath)) {
    $execObj = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($execObj) {
      if ($execObj.command) { $Command = [string]$execObj.command }
      if ($execObj.cliPath) { $CliPath = [string]$execObj.cliPath }
      if ($execObj.exitCode -ne $null) { $ExitCode = [int]$execObj.exitCode }
      if ($execObj.duration_s -ne $null) { $DurationSeconds = [double]$execObj.duration_s }
      if ($execObj.base) { $Base = [string]$execObj.base }
      if ($execObj.head) { $Head = [string]$execObj.head }
      if ($execObj.diff -ne $null) {
        $Diff = if ([bool]$execObj.diff) { 'true' } else { 'false' }
      }
      $source = 'execJson'
    }
  }
} catch { Write-Host "[report] warn: failed to load exec json: $_" -ForegroundColor DarkYellow }

function Get-BaseHeadFromCommand([string]$cmd) {
  # Tokenize respecting quotes: match quoted strings (preserving quotes) or non-space sequences
  # This pattern matches: "quoted strings" OR non-whitespace sequences
  $pattern = Get-LVCompareArgTokenPattern
  $tokens = [regex]::Matches($cmd, $pattern) | ForEach-Object { 
    $val = $_.Value
    # Remove surrounding quotes if present
    if ($val.StartsWith('"') -and $val.EndsWith('"')) {
      $val.Substring(1, $val.Length - 2)
    } else {
      $val
    }
  }
  if ($tokens.Count -ge 3) {
    return [pscustomobject]@{ Base = $tokens[1]; Head = $tokens[2] }
  }
  return $null
}

if (-not $Base -or -not $Head) {
  $parsed = Get-BaseHeadFromCommand $Command
  if ($parsed) { $Base = $parsed.Base; $Head = $parsed.Head }
}

$diffBool = $false
if ($Diff -ieq 'true') { $diffBool = $true }

$status = if ($diffBool) { 'Differences detected' } else { 'No differences' }
$color  = if ($diffBool) { '#b91c1c' } else { '#065f46' }

$exitMap = @{
  0 = 'No differences (0)'
  1 = 'Differences detected (1)'
}
$exitText = $exitMap[$ExitCode]
if (-not $exitText) { $exitText = "Unknown/Failure ($ExitCode)" }

$now = (Get-Date).ToString('u')

# Optional content check (bytes/SHA) when base/head available
$baseBytes = $null; $headBytes = $null; $baseSha = $null; $headSha = $null; $expectDiff = $null
try {
  if ($Base -and (Test-Path -LiteralPath $Base -PathType Leaf)) {
    $baseBytes = (Get-Item -LiteralPath $Base).Length
    $baseSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Base).Hash.ToUpperInvariant()
  }
  if ($Head -and (Test-Path -LiteralPath $Head -PathType Leaf)) {
    $headBytes = (Get-Item -LiteralPath $Head).Length
    $headSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Head).Hash.ToUpperInvariant()
  }
  if ($baseBytes -ne $null -and $headBytes -ne $null -and $baseSha -and $headSha) {
    $expectDiff = (($baseBytes -ne $headBytes) -or ($baseSha -ne $headSha))
  }
} catch {}

# Live process snapshot at render time
$liveLVCompare = @(); $liveLabVIEW = @()
try { $liveLVCompare = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
try { $liveLabVIEW   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}

# Render Meta: end timestamp and new process deltas
$renderEnd = Get-Date
$renderMs  = [int]([Math]::Round(($renderEnd - $renderStart).TotalMilliseconds))
$newLVCompare = @()
if ($preLVCompare -and $preLVCompare.Count -gt 0) {
  $preSet = @{}; foreach($i in $preLVCompare){ $preSet[[string]$i]=$true }
  foreach($p in $liveLVCompare){ if (-not $preSet.ContainsKey([string]$p)) { $newLVCompare += $p } }
} else { $newLVCompare = $liveLVCompare }
$newLabVIEW = @()
if ($preLabVIEW -and $preLabVIEW.Count -gt 0) {
  $preSet2 = @{}; foreach($i in $preLabVIEW){ $preSet2[[string]$i]=$true }
  foreach($p in $liveLabVIEW){ if (-not $preSet2.ContainsKey([string]$p)) { $newLabVIEW += $p } }
} else { $newLabVIEW = $liveLabVIEW }

$css = @'
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #111827; }
h1 { font-size: 20px; }
 .nav { position: sticky; top: 0; background: #ffffff; margin: 10px 0 16px 0; padding-bottom: 8px; border-bottom: 1px solid #e5e7eb; z-index: 10; }
.nav a { margin-right: 10px; color: #2563eb; text-decoration: none; font-weight: 600; }
.nav a:hover { text-decoration: underline; }
.section { margin: 16px 0; padding: 14px; border: 1px solid #e5e7eb; border-radius: 8px; background: #ffffff; box-shadow: 0 1px 2px rgba(0,0,0,0.03); }
.section h2 { margin: 0 0 10px 0; font-size: 16px; color: #111827; }
.kv { display: grid; grid-template-columns: 180px 1fr; row-gap: 6px; }
.key { color: #6b7280; }
.value { color: #111827; word-break: break-all; }
.status { padding: 10px; border-radius: 6px; color: white; font-weight: 600; }
.code { font-family: Consolas, monospace; background: #f3f4f6; padding: 8px; border-radius: 6px; }
.badges { margin-top: 8px; }
.badge { display: inline-block; padding: 3px 8px; border-radius: 999px; font-size: 12px; margin-right: 6px; }
.badge-ok { background: #10b981; color: #ffffff; }
.badge-warn { background: #f59e0b; color: #111827; }
.badge-danger { background: #ef4444; color: #ffffff; }
.badge-muted { background: #e5e7eb; color: #374151; }
.mono { font-family: Consolas, monospace; }
.dim { color: #6b7280; }
 details summary { cursor: pointer; font-weight: 600; }
'@

# Extra accent styles (appended)
$css += @'
.highlight-danger { border-color: #ef4444 !important; box-shadow: 0 0 0 1px rgba(239,68,68,0.12) inset; }
.highlight-warn   { border-color: #f59e0b !important; box-shadow: 0 0 0 1px rgba(245,158,11,0.12) inset; }
.btn { display:inline-block; padding:4px 8px; border:1px solid #d1d5db; border-radius:6px; background:#f9fafb; color:#111827; font-size:12px; cursor:pointer; }
.btn:hover { background:#f3f4f6; }
'@

# Optional sections
$contentCheckHtml = ''
if ($expectDiff -ne $null) {
  $contentCheckHtml = @"
  <div class=\"section\">
    <div class=\"kv\">
      <div class=\"key\">Base bytes</div><div class=\"value\">$baseBytes</div>
      <div class=\"key\">Head bytes</div><div class=\"value\">$headBytes</div>
      <div class=\"key\">Base SHA256</div><div class=\"value\">$baseSha</div>
      <div class=\"key\">Head SHA256</div><div class=\"value\">$headSha</div>
      <div class=\"key\">Content Expect Diff</div><div class=\"value\">$expectDiff</div>
    </div>
  </div>
"@
}

$liveLVCompareStr = if ($liveLVCompare -and $liveLVCompare.Count -gt 0) { ($liveLVCompare -join ', ') } else { 'none' }
$liveLabVIEWStr   = if ($liveLabVIEW   -and $liveLabVIEW.Count   -gt 0) { ($liveLabVIEW   -join ', ') } else { 'none' }

$liveSectionClass = if ( (($liveLVCompare | Measure-Object).Count + ($liveLabVIEW | Measure-Object).Count) -gt 0 ) { ' highlight-warn' } else { '' }
$liveProcsHtml = ('<div class="section{0}"><h2 id="processes">Processes</h2><div class="kv"><div class="key">Live LVCompare PIDs</div><div class="value">{1}</div><div class="key">Live LabVIEW PIDs</div><div class="value">{2}</div></div></div>' -f $liveSectionClass, $liveLVCompareStr, $liveLabVIEWStr)

$anomalyText = if ($expectDiff -ne $null -and $expectDiff -ne $diffBool) { 'Mismatch: CLI diff and content check disagree' } else { 'None' }

$anomalySectionClass = if ($anomalyText -ne 'None') { ' highlight-danger' } else { '' }
$anomalyHtml = ('<div class="section{0}"><h2 id="anomalies">Anomalies</h2><div class="kv"><div class="key">Status</div><div class="value">{1}</div></div></div>' -f $anomalySectionClass, $anomalyText)

# Render Meta HTML
$renderWarnClass = if ( ($newLVCompare.Count -gt 0) -or ($newLabVIEW.Count -gt 0) ) { ' highlight-warn' } else { '' }
$renderMetaHtml = ('<div class="section{0}"><h2 id="rendermeta">Render Meta</h2><div class="kv"><div class="key">Start (UTC)</div><div class="value">{1}</div><div class="key">End (UTC)</div><div class="value">{2}</div><div class="key">Render Time</div><div class="value">{3} ms</div><div class="key">Pre LVCompare</div><div class="value">{4}</div><div class="key">Pre LabVIEW</div><div class="value">{5}</div><div class="key">Post LVCompare</div><div class="value">{6}</div><div class="key">Post LabVIEW</div><div class="value">{7}</div><div class="key">New LVCompare</div><div class="value">{8}</div><div class="key">New LabVIEW</div><div class="value">{9}</div></div></div>' -f $renderWarnClass, $renderStart.ToUniversalTime().ToString('u'), $renderEnd.ToUniversalTime().ToString('u'), $renderMs, ($preLVCompare -join ', '), ($preLabVIEW -join ', '), ($liveLVCompare -join ', '), ($liveLabVIEW -join ', '), ($newLVCompare -join ', '), ($newLabVIEW -join ', '))

$envOs  = [System.Environment]::OSVersion.VersionString
$envPs  = $PSVersionTable.PSVersion.ToString()
$envCwd = $null; try { $envCwd = (Get-Location).Path } catch { $envCwd = $null }
$toggles = @{
  'LV_SUPPRESS_UI'            = $env:LV_SUPPRESS_UI
  'LV_NO_ACTIVATE'            = $env:LV_NO_ACTIVATE
  'LV_CURSOR_RESTORE'         = $env:LV_CURSOR_RESTORE
  'LV_IDLE_WAIT_SECONDS'      = $env:LV_IDLE_WAIT_SECONDS
  'LV_IDLE_MAX_WAIT_SECONDS'  = $env:LV_IDLE_MAX_WAIT_SECONDS
  'ENABLE_LABVIEW_CLEANUP'    = $env:ENABLE_LABVIEW_CLEANUP
}
$envHtml = @"
  <div class=\"section\">
    <h2 id=\"env\">Environment & Toggles</h2>
    <div class=\"kv\">
      <div class=\"key\">OS</div><div class=\"value\">$envOs</div>
      <div class=\"key\">PowerShell</div><div class=\"value\">$envPs</div>
      <div class=\"key\">Working Dir</div><div class=\"value\">$envCwd</div>
      <div class=\"key\">Toggles</div><div class=\"value\">LV_SUPPRESS_UI=$($toggles['LV_SUPPRESS_UI']); LV_NO_ACTIVATE=$($toggles['LV_NO_ACTIVATE']); LV_CURSOR_RESTORE=$($toggles['LV_CURSOR_RESTORE']); LV_IDLE_WAIT_SECONDS=$($toggles['LV_IDLE_WAIT_SECONDS']); LV_IDLE_MAX_WAIT_SECONDS=$($toggles['LV_IDLE_MAX_WAIT_SECONDS']); ENABLE_LABVIEW_CLEANUP=$($toggles['ENABLE_LABVIEW_CLEANUP'])</div>
    </div>
  </div>
"@

# Artifact map from output folder
$outDir = Split-Path -Parent $OutputPath
$artList = @()
if ($ExecJsonPath) { try { $artList += (Resolve-Path -LiteralPath $ExecJsonPath).Path } catch {} }
foreach($cand in @('compare-exec.json','lvcompare-capture.json','fixture-verify-summary.json','ref-compare-summary.json','session-index.json','rogue-lv-detection.json')) {
  $p = Join-Path $outDir $cand; if (Test-Path -LiteralPath $p) { $artList += (Resolve-Path -LiteralPath $p).Path }
}
try { Get-ChildItem -Path $outDir -Filter '*-summary.json' | ForEach-Object { $artList += $_.FullName } } catch {}
$artList = $artList | Sort-Object -Unique
$artRows = @(); foreach ($a in $artList) { $artRows += ('<div class="key">File</div><div class="value">{0}</div>' -f $a) }
$artHtml = ''
if ($artRows.Count -gt 0) {
  $joined = [string]::Join('', $artRows)
  $artHtml = ('<div class="section"><h2 id="artifacts">Artifacts</h2><div class="kv">{0}</div></div>' -f $joined)
}

# Exec JSON embed (preview)
$execEmbed = ''
try {
  $embedPath = if ($ExecJsonPath) { $ExecJsonPath } else { Join-Path $outDir 'compare-exec.json' }
  if ($embedPath -and (Test-Path -LiteralPath $embedPath)) {
    $raw = Get-Content -LiteralPath $embedPath -Raw
    $pretty = try { ($raw | ConvertFrom-Json | ConvertTo-Json -Depth 8) } catch { $raw }
    $max = 8000; if ($pretty.Length -gt $max) { $pretty = $pretty.Substring(0,$max) + "`n... (truncated)" }
    $enc = [System.Net.WebUtility]::HtmlEncode($pretty)
    $execEmbed = ('<div class="section"><h2 id="execjson">Exec JSON</h2><details><summary>Preview</summary><pre class="code">{0}</pre></details></div>' -f $enc)
  }
} catch {}

# Verification signature (canonical summary + SHA-256)
$verificationHtml = ''
try {
  $canon = [ordered]@{
    schema = 'compare-verification/v1'
    generatedAt = (Get-Date).ToString('o')
    cli = [ordered]@{
      exitCode = $ExitCode
      diff = $diffBool
      cliPath = $CliPath
      duration_s = $DurationSeconds
    }
    content = [ordered]@{
      baseBytes = $baseBytes
      baseSha = $baseSha
      headBytes = $headBytes
      headSha = $headSha
      expectDiff = $expectDiff
    }
    inputs = [ordered]@{
      base = $Base
      head = $Head
      command = $Command
    }
    toggles = [ordered]@{
      LV_SUPPRESS_UI = $toggles['LV_SUPPRESS_UI']
      LV_NO_ACTIVATE = $toggles['LV_NO_ACTIVATE']
      LV_CURSOR_RESTORE = $toggles['LV_CURSOR_RESTORE']
      LV_IDLE_WAIT_SECONDS = $toggles['LV_IDLE_WAIT_SECONDS']
      LV_IDLE_MAX_WAIT_SECONDS = $toggles['LV_IDLE_MAX_WAIT_SECONDS']
      ENABLE_LABVIEW_CLEANUP = $toggles['ENABLE_LABVIEW_CLEANUP']
    }
    anomalies = $anomalyText
  }
  $canonJson = ($canon | ConvertTo-Json -Depth 8)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonJson)
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  $hash = $hasher.ComputeHash($bytes)
  $sig = -join ($hash | ForEach-Object { $_.ToString('x2') })
  # Write signature file next to report
  $sigPath = Join-Path $outDir (([System.IO.Path]::GetFileNameWithoutExtension($OutputPath)) + '.signature.txt')
  "algorithm: SHA-256`nsignature: $sig`ngenerated: $(Get-Date -Format o)" | Out-File -FilePath $sigPath -Encoding utf8
  # Embed signature and canonical JSON preview
  $canonEnc = [System.Net.WebUtility]::HtmlEncode($canonJson)
  $verificationHtml = @'
<div class="section"><h2 id="verification">Verification</h2><div class="kv"><div class="key">Algorithm</div><div class="value">SHA-256</div><div class="key">Signature</div><div class="value mono"><span id="sigval">{0}</span> <button class="btn" onclick="copyText('sigval')">Copy</button></div><div class="key">Signature File</div><div class="value mono">{1}</div></div><details><summary>Canonical Summary (preview)</summary><pre class="code">{2}</pre></details></div>
'@ -f $sig, [System.Net.WebUtility]::HtmlEncode($sigPath), $canonEnc
} catch {}

# Agent trace (commands used)
$traceHtml = ''
try {
  $traceItems = @()
  # Renderer command (reconstructed)
  $rendererCmd = $null
  if ($ExecJsonPath -or (Test-Path -LiteralPath (Join-Path $outDir 'compare-exec.json'))) {
    $execArg = if ($ExecJsonPath) { (Resolve-Path -LiteralPath $ExecJsonPath).Path } else { (Resolve-Path -LiteralPath (Join-Path $outDir 'compare-exec.json')).Path }
    $rendererCmd = ('pwsh -NoLogo -NoProfile -File scripts/Render-CompareReport.ps1 -ExecJsonPath "{0}" -OutputPath "{1}"' -f $execArg, (Resolve-Path -LiteralPath $OutputPath).Path)
    $traceItems += [pscustomobject]@{ title='Render Report'; cmd=$rendererCmd }
  }
  # CompareVI CLI (from exec json)
  if ($Command) { $traceItems += [pscustomobject]@{ title='LVCompare CLI'; cmd=$Command } }
  # Verify fixture (if summary present)
  $verifySum = Join-Path $outDir 'fixture-verify-summary.json'
  if (Test-Path -LiteralPath $verifySum) {
    $vx = try { Get-Content -LiteralPath $verifySum -Raw | ConvertFrom-Json } catch { $null }
    if ($vx) {
      $vxExec = if ($ExecJsonPath) { (Resolve-Path -LiteralPath $ExecJsonPath).Path } else { (Join-Path $outDir 'compare-exec.json') }
      $verifyCmd = ('pwsh -NoLogo -NoProfile -File tools/Verify-FixtureCompare.ps1 -ExecJsonPath "{0}" -ResultsDir "{1}" -VerboseOutput' -f $vxExec, (Resolve-Path -LiteralPath $outDir).Path)
      $traceItems += [pscustomobject]@{ title='Verify Fixture'; cmd=$verifyCmd }
    }
  }
  # Ref compare (if summary present)
  $refSum = Join-Path $outDir 'ref-compare-summary.json'
  if (Test-Path -LiteralPath $refSum) {
    $rx = try { Get-Content -LiteralPath $refSum -Raw | ConvertFrom-Json } catch { $null }
    if ($rx -and $rx.path -and $rx.refA -and $rx.refB) {
      $outName = try { [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf (Join-Path $outDir 'compare-exec.json'))) } catch { 'vi-refs' }
      $refCmd = ('pwsh -NoLogo -NoProfile -File tools/Compare-RefsToTemp.ps1 -Path "{0}" -RefA {1} -RefB {2} -ResultsDir "{3}" -OutName "{4}"' -f $rx.path, $rx.refA, $rx.refB, (Resolve-Path -LiteralPath $outDir).Path, $outName)
      $traceItems += [pscustomobject]@{ title='Compare Refs'; cmd=$refCmd }
    }
  }
  # Optional agent command log embed if present
  $traceRows = @()
  $i = 0
  foreach ($t in $traceItems) { $i++; $id = 'trace' + $i; $enc = [System.Net.WebUtility]::HtmlEncode([string]$t.cmd); $traceRows += ('<div class="key">{0}</div><div class="value"><span id="{1}">{2}</span> <button class="btn" onclick="copyText(''{1}'')">Copy</button></div>' -f $t.title, $id, $enc) }
  if ($traceRows.Count -gt 0) {
    $traceHtml = ('<div class="section"><h2 id="trace">Agent Trace</h2><div class="kv">{0}</div></div>' -f ([string]::Join('', $traceRows)))
  }
} catch {}

# Status badges
$cliText = if ($diffBool) { 'CLI: Differences' } else { 'CLI: No diff' }
$cliClass = if ($diffBool) { 'badge-danger' } else { 'badge-ok' }
$contentText = if ($expectDiff -eq $true) { 'Content: Different' } elseif ($expectDiff -eq $false) { 'Content: Equal' } else { 'Content: Unknown' }
$contentClass = if ($expectDiff -eq $true) { 'badge-danger' } elseif ($expectDiff -eq $false) { 'badge-ok' } else { 'badge-muted' }
$anomalyClass = if ($anomalyText -eq 'None') { 'badge-muted' } else { 'badge-warn' }
$liveCount = (($liveLVCompare | Measure-Object).Count + ($liveLabVIEW | Measure-Object).Count)
$liveText = if ($liveCount -gt 0) { "Live: $liveCount proc(s)" } else { 'Live: none' }
$liveClass = if ($liveCount -gt 0) { 'badge-warn' } else { 'badge-muted' }

# Optional single-run diff details
$headChanges = $null; $baseChanges = $null
try {
  $detailsDir = $null
  if ($OutputPath) { try { $detailsDir = (Split-Path -Parent -LiteralPath $OutputPath) } catch {} }
  if (-not $detailsDir -and $ExecJsonPath) { try { $detailsDir = (Split-Path -Parent -LiteralPath $ExecJsonPath) } catch {} }
  if ($detailsDir) {
    $dd = Join-Path $detailsDir 'diff-details.json'
    if (Test-Path -LiteralPath $dd -PathType Leaf) {
      $dj = Get-Content -LiteralPath $dd -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($dj) {
        if ($dj.PSObject.Properties.Name -contains 'headChanges') { try { $headChanges = [int]$dj.headChanges } catch {} }
        if ($dj.PSObject.Properties.Name -contains 'baseChanges') { try { $baseChanges = [int]$dj.baseChanges } catch {} }
      }
    }
  }
} catch { Write-Host "[report] warn: failed to load diff-details.json: $_" -ForegroundColor DarkYellow }

$statusBadgesHtml = ('<div class="badges"><span class="badge {0}">{1}</span><span class="badge {2}">{3}</span><span class="badge {4}">{5}</span><span class="badge {6}">{7}</span></div>' -f $cliClass,$cliText,$contentClass,$contentText,$anomalyClass,$anomalyText,$liveClass,$liveText)

# Top navigation
$navHtml = @"
<div class=\"nav\">
  <a href=\"#summary\">Summary</a>
  <a href=\"#content\">Content</a>
  <a href=\"#processes\">Processes</a>
  <a href=\"#rendermeta\">Render Meta</a>
  <a href=\"#anomalies\">Anomalies</a>
  <a href=\"#env\">Environment</a>
  <a href=\"#artifacts\">Artifacts</a>
  <a href=\"#execjson\">Exec JSON</a>
  <a href=\"#trace\">Trace</a>
  <a href=\"#command\">Command</a>
</div>
"@

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>Compare VI Report</title>
<style>
$css
</style>
<script>
function copyText(id){
  try {
    var el = document.getElementById(id);
    if (!el) return;
    var text = (el.innerText || el.textContent || '').trim();
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text);
    } else {
      var ta = document.createElement('textarea');
      ta.value = text; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); document.body.removeChild(ta);
    }
  } catch (e) { console.log('copy failed', e); }
}
</script>
</head>
<body>
  <h1>Compare VI Report</h1>
  $navHtml
  <div class="section">
    <div class="status" style="background: $color;">$status</div>
    $statusBadgesHtml
  </div>
  <div class="section">
    <h2 id="summary">Summary</h2>
    <div class="kv">
      <div class="key">Generated</div><div class="value">$now</div>
      <div class="key">Source</div><div class="value">$source</div>
      <div class="key">Exit code</div><div class="value">$ExitCode ($exitText)</div>
      <div class="key">Diff</div><div class="value">$Diff</div>
      $(if ($headChanges -ne $null) { '<div class="key">Head Changes</div><div class="value">' + $headChanges + '</div>' } else { '' })
      $(if ($baseChanges -ne $null) { '<div class="key">Base Changes</div><div class="value">' + $baseChanges + '</div>' } else { '' })
  <div class="key">CLI Path</div><div class="value"><span id="clip_cli">$CliPath</span> <button class="btn" onclick="copyText('clip_cli')">Copy</button></div>
  <div class="key">Duration (s)</div><div class="value">$([string]::Format('{0:F3}', $DurationSeconds))</div>
      <div class="key">Base</div><div class="value"><span id="clip_base">$Base</span> <button class="btn" onclick="copyText('clip_base')">Copy</button></div>
      <div class="key">Head</div><div class="value"><span id="clip_head">$Head</span> <button class="btn" onclick="copyText('clip_head')">Copy</button></div>
    </div>
  </div>
  $contentCheckHtml
  $liveProcsHtml
  $anomalyHtml
  $renderMetaHtml
  $envHtml
  $artHtml
  $execEmbed
  $verificationHtml
  $traceHtml
  <div class="section">
    <h2 id="command">Command</h2>
    <div class="key">Command</div>
    <div class="code"><span id="cmdval">$([System.Net.WebUtility]::HtmlEncode($Command))</span> <button class="btn" onclick="copyText('cmdval')">Copy</button></div>
  </div>
</body>
</html>
"@

if (-not $OutputPath) {
  $outDir = Join-Path $PSScriptRoot '..' 'tests' 'results'
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  $OutputPath = Join-Path $outDir 'compare-report.html'
}

$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host ("Report written: {0}" -f (Resolve-Path $OutputPath).Path)

