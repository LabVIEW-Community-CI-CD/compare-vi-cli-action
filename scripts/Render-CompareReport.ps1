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

function HtmlEncode {
  param([object]$Value)
  if ($null -eq $Value) { return '' }
  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

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

$cliInfo = [ordered]@{
  Path = if ($CliPath) { [string]$CliPath } else { $null }
  ReportType = $null
  ReportPath = $null
  Status = $null
  Message = $null
  Mode = $null
  Policy = $null
}

if ($execObj) {
  if ($execObj.cliPath) { $cliInfo.Path = [string]$execObj.cliPath }
  if ($execObj.PSObject.Properties.Name -contains 'environment') {
    $envBlock = $execObj.environment
    if ($envBlock) {
      if ($envBlock.PSObject.Properties.Name -contains 'compareMode' -and $envBlock.compareMode) { $cliInfo.Mode = [string]$envBlock.compareMode }
      if ($envBlock.PSObject.Properties.Name -contains 'comparePolicy' -and $envBlock.comparePolicy) { $cliInfo.Policy = [string]$envBlock.comparePolicy }
      if ($envBlock.PSObject.Properties.Name -contains 'cli') {
        $cliBlock = $envBlock.cli
        if ($cliBlock) {
          if ($cliBlock.PSObject.Properties.Name -contains 'path' -and $cliBlock.path) { $cliInfo.Path = [string]$cliBlock.path }
          if ($cliBlock.PSObject.Properties.Name -contains 'reportType' -and $cliBlock.reportType) { $cliInfo.ReportType = [string]$cliBlock.reportType }
          if ($cliBlock.PSObject.Properties.Name -contains 'reportPath' -and $cliBlock.reportPath) { $cliInfo.ReportPath = [string]$cliBlock.reportPath }
          if ($cliBlock.PSObject.Properties.Name -contains 'status' -and $cliBlock.status) { $cliInfo.Status = [string]$cliBlock.status }
          if ($cliBlock.PSObject.Properties.Name -contains 'message' -and $cliBlock.message) { $cliInfo.Message = [string]$cliBlock.message }
          if ($cliBlock.PSObject.Properties.Name -contains 'artifacts' -and $cliBlock.artifacts) { $cliInfo.Artifacts = $cliBlock.artifacts }
        }
      }
    }
  }
}

if (-not $cliInfo.Mode -and $env:LVCI_COMPARE_MODE) { $cliInfo.Mode = $env:LVCI_COMPARE_MODE }
if (-not $cliInfo.Policy -and $env:LVCI_COMPARE_POLICY) { $cliInfo.Policy = $env:LVCI_COMPARE_POLICY }
if ($cliInfo.Path -and -not $CliPath) { $CliPath = $cliInfo.Path }

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
$headChanges = $null; $baseChanges = $null; $diffDetailsChecked = $false; $diffDetailsFound = $false
try {
  $candidateDirs = New-Object System.Collections.Generic.List[string]
  function Add-CandidateDir {
    param([string]$Dir)
    if ($Dir -and -not ($candidateDirs -contains $Dir)) {
      $null = $candidateDirs.Add($Dir)
    }
  }
  function Get-ParentDirectory {
    param([string]$PathValue)
    if ($null -eq $PathValue -or $PathValue -eq '') { return $null }
    try { return Split-Path -Path $PathValue -Parent } catch { return [System.IO.Path]::GetDirectoryName($PathValue) }
  }
  if ($OutputPath) { Add-CandidateDir (Get-ParentDirectory $OutputPath) }
  if ($ExecJsonPath) { Add-CandidateDir (Get-ParentDirectory $ExecJsonPath) }

  function Try-LoadDiffDetails {
    param(
      [string]$Dir,
      [ref]$HeadOut,
      [ref]$BaseOut,
      [ref]$FoundOut
    )
    if (-not $Dir) { return }
    $path = Join-Path $Dir 'diff-details.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($data) {
        if ($data.PSObject.Properties.Name -contains 'headChanges') { try { $HeadOut.Value = [int]$data.headChanges } catch {} }
        if ($data.PSObject.Properties.Name -contains 'baseChanges') { try { $BaseOut.Value = [int]$data.baseChanges } catch {} }
        $FoundOut.Value = $true
      }
    }
  }

  foreach ($dir in $candidateDirs) {
    $diffDetailsChecked = $true
    Try-LoadDiffDetails -Dir $dir -HeadOut ([ref]$headChanges) -BaseOut ([ref]$baseChanges) -FoundOut ([ref]$diffDetailsFound)
    if ($diffDetailsFound) { break }
  }

  if (-not $diffDetailsFound) {
    $fallbackDirs = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $candidateDirs) {
      try {
        $parent = if ($dir) { Get-ParentDirectory $dir } else { $null }
        if ($parent) {
          $outDirs = @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'out' -ErrorAction SilentlyContinue)
          foreach ($entry in $outDirs) {
            if ($entry -and $entry.FullName -and -not ($candidateDirs | Where-Object { $_ -ieq $entry.FullName }) -and -not ($fallbackDirs | Where-Object { $_ -ieq $entry.FullName })) {
              $null = $fallbackDirs.Add($entry.FullName)
            }
          }
        }
      } catch {}
    }
    foreach ($dir in $fallbackDirs) {
      $diffDetailsChecked = $true
      Try-LoadDiffDetails -Dir $dir -HeadOut ([ref]$headChanges) -BaseOut ([ref]$baseChanges) -FoundOut ([ref]$diffDetailsFound)
      if ($diffDetailsFound) { break }
    }
  }
} catch { Write-Host "[report] warn: failed to load diff-details.json: $_" -ForegroundColor DarkYellow }

$statusBadgesHtml = ('<div class="badges"><span class="badge {0}">{1}</span><span class="badge {2}">{3}</span><span class="badge {4}">{5}</span><span class="badge {6}">{7}</span></div>' -f $cliClass,$cliText,$contentClass,$contentText,$anomalyClass,$anomalyText,$liveClass,$liveText)

$cliSummaryLines = @()
if ($cliInfo.Path) {
  $encPath = HtmlEncode($cliInfo.Path)
  $cliSummaryLines += ('<div class="key">CLI Path</div><div class="value"><span id="clip_cli" data-cli-path="{0}">{0}</span> <button class="btn" onclick="copyText(''clip_cli'')">Copy</button></div>' -f $encPath)
}
if ($cliInfo.ReportType) {
  $cliSummaryLines += ('<div class="key">CLI Report Type</div><div class="value" data-cli-report-type="{0}">{0}</div>' -f (HtmlEncode($cliInfo.ReportType)))
}
if ($cliInfo.ReportPath) {
  $encReport = HtmlEncode($cliInfo.ReportPath)
  $cliSummaryLines += ('<div class="key">CLI Report Path</div><div class="value"><span id="clip_cli_report" data-cli-report-path="{0}">{0}</span> <button class="btn" onclick="copyText(''clip_cli_report'')">Copy</button></div>' -f $encReport)
}
if ($cliInfo.Status) {
  $cliSummaryLines += ('<div class="key">CLI Status</div><div class="value" data-cli-status="{0}">{0}</div>' -f (HtmlEncode($cliInfo.Status)))
}
if ($cliInfo.Message) {
  $cliSummaryLines += ('<div class="key">CLI Message</div><div class="value" data-cli-message="{0}">{0}</div>' -f (HtmlEncode($cliInfo.Message)))
}
$modeVal = if ($cliInfo.Mode) { $cliInfo.Mode } else { $null }
$policyVal = if ($cliInfo.Policy) { $cliInfo.Policy } else { $null }
$artifactsVal = $null
if ($cliInfo -is [System.Collections.IDictionary]) {
  if ($cliInfo.Contains('Artifacts') -and $cliInfo['Artifacts']) { $artifactsVal = $cliInfo['Artifacts'] }
  elseif ($cliInfo.Contains('artifacts') -and $cliInfo['artifacts']) { $artifactsVal = $cliInfo['artifacts'] }
} elseif ($cliInfo.PSObject.Properties.Name -contains 'Artifacts' -and $cliInfo.Artifacts) {
  $artifactsVal = $cliInfo.Artifacts
} elseif ($cliInfo.PSObject.Properties.Name -contains 'artifacts' -and $cliInfo.artifacts) {
  $artifactsVal = $cliInfo.artifacts
}
if ($modeVal -or $policyVal) {
  $modeDisplay = if ($modeVal) { $modeVal } else { '-' }
  $policyDisplay = if ($policyVal) { $policyVal } else { '-' }
  $modeSegment = if ($modeVal) { $modeVal } else { '' }
  $policySegment = if ($policyVal) { $policyVal } else { '' }
  $policyData = HtmlEncode(($modeSegment + '|' + $policySegment))
  $cliSummaryLines += ('<div class="key">Compare Mode / Policy</div><div class="value" data-cli-policy="{0}">{1}</div>' -f $policyData, (HtmlEncode("$modeDisplay / $policyDisplay")))
}
if ($artifactsVal) {
  $reportSizeBytes = if ($artifactsVal -is [System.Collections.IDictionary]) { $artifactsVal['reportSizeBytes'] } elseif ($artifactsVal.PSObject.Properties.Name -contains 'reportSizeBytes') { $artifactsVal.reportSizeBytes } else { $null }
  if ($reportSizeBytes -ne $null) {
    $reportSizeEnc = HtmlEncode($reportSizeBytes)
    $cliSummaryLines += ('<div class="key">CLI Report Size</div><div class="value" data-cli-report-size="{0}">{0} bytes</div>' -f $reportSizeEnc)
  }
  $imageCountVal = if ($artifactsVal -is [System.Collections.IDictionary]) { $artifactsVal['imageCount'] } elseif ($artifactsVal.PSObject.Properties.Name -contains 'imageCount') { $artifactsVal.imageCount } else { $null }
  if ($imageCountVal -ne $null) {
    $cliSummaryLines += ('<div class="key">CLI Images</div><div class="value" data-cli-image-count="{0}">{0}</div>' -f (HtmlEncode($imageCountVal)))
  }
  $exportDirVal = if ($artifactsVal -is [System.Collections.IDictionary]) { $artifactsVal['exportDir'] } elseif ($artifactsVal.PSObject.Properties.Name -contains 'exportDir') { $artifactsVal.exportDir } else { $null }
  if ($exportDirVal) {
    $exportEnc = HtmlEncode($exportDirVal)
    $cliSummaryLines += ('<div class="key">CLI Image Export</div><div class="value" data-cli-image-export="{0}"><span id="clip_cli_image_export">{0}</span> <button class="btn" onclick="copyText(''clip_cli_image_export'')">Copy</button></div>' -f $exportEnc)
  }
  $imagesVal = if ($artifactsVal -is [System.Collections.IDictionary]) { $artifactsVal['images'] } elseif ($artifactsVal.PSObject.Properties.Name -contains 'images') { $artifactsVal.images } else { $null }
  if ($imagesVal) {
    $imageIndex = 0
foreach ($image in $imagesVal) {
      if (-not $image) { continue }
      $idxValue = if ($image -is [System.Collections.IDictionary]) { $image['index'] } elseif ($image.PSObject.Properties.Name -contains 'index') { $image.index } else { $imageIndex }
      $idxEnc = HtmlEncode($idxValue)
      $mimeValue = if ($image -is [System.Collections.IDictionary]) { $image['mimeType'] } elseif ($image.PSObject.Properties.Name -contains 'mimeType') { $image.mimeType } else { $null }
      $byteLengthValue = if ($image -is [System.Collections.IDictionary]) { $image['byteLength'] } elseif ($image.PSObject.Properties.Name -contains 'byteLength') { $image.byteLength } else { $null }
      $dataLengthValue = if ($image -is [System.Collections.IDictionary]) { $image['dataLength'] } elseif ($image.PSObject.Properties.Name -contains 'dataLength') { $image.dataLength } else { $null }
      $savedPathValue = if ($image -is [System.Collections.IDictionary]) { $image['savedPath'] } elseif ($image.PSObject.Properties.Name -contains 'savedPath') { $image.savedPath } else { $null }
      $valueParts = @()
      if ($mimeValue) { $valueParts += [string]$mimeValue }
      if ($byteLengthValue -ne $null) { $valueParts += ("{0} bytes" -f $byteLengthValue) }
      if ($valueParts.Count -eq 0 -and $dataLengthValue -ne $null) { $valueParts += ("data length {0}" -f $dataLengthValue) }
      $displayText = if ($savedPathValue) { [string]$savedPathValue } elseif ($valueParts.Count -gt 0) { [string]::Join(' · ', $valueParts) } else { 'Image' }
      $displayEnc = HtmlEncode($displayText)
      $attrList = @("data-cli-image-index=""{0}""" -f $idxEnc)
      if ($savedPathValue) { $attrList += ("data-cli-image-path=""{0}""" -f (HtmlEncode($savedPathValue))) }
      if ($byteLengthValue -ne $null) { $attrList += ("data-cli-image-bytes=""{0}""" -f (HtmlEncode($byteLengthValue))) }
      if ($mimeValue) { $attrList += ("data-cli-image-mime=""{0}""" -f (HtmlEncode($mimeValue))) }
      $attrString = if ($attrList.Count -gt 0) { ' ' + ([string]::Join(' ', $attrList)) } else { '' }
      $copyId = 'clip_cli_image_' + $idxValue
      $buttonHtml = ''
      if ($savedPathValue) { $buttonHtml = (' <button class="btn" onclick="copyText(''{0}'')">Copy</button>' -f $copyId) }
      $cliSummaryLines += ('<div class="key">CLI Image {0}</div><div class="value"{1}><span id="{2}">{3}</span>{4}</div>' -f $idxEnc, $attrString, $copyId, $displayEnc, $buttonHtml)
      $imageIndex++
    }
  }
}

$summaryKvRows = @()
$summaryKvRows += ('<div class="key">Generated</div><div class="value">{0}</div>' -f (HtmlEncode($now)))
$summaryKvRows += ('<div class="key">Source</div><div class="value">{0}</div>' -f (HtmlEncode($source)))
$summaryKvRows += ('<div class="key">Exit code</div><div class="value">{0}</div>' -f (HtmlEncode("$ExitCode ($exitText)")))
$summaryKvRows += ('<div class="key">Diff</div><div class="value">{0}</div>' -f (HtmlEncode($Diff)))
if ($headChanges -ne $null) { $summaryKvRows += ('<div class="key">Head Changes</div><div class="value">{0}</div>' -f (HtmlEncode($headChanges))) }
if ($baseChanges -ne $null) { $summaryKvRows += ('<div class="key">Base Changes</div><div class="value">{0}</div>' -f (HtmlEncode($baseChanges))) }
if ($diffBool -and -not $diffDetailsFound -and $diffDetailsChecked) {
  $summaryKvRows += '<div class="key">Diff details</div><div class="value">Not available</div>'
}
$summaryKvRows += ('<div class="key">Duration (s)</div><div class="value">{0}</div>' -f (HtmlEncode(([string]::Format('{0:F3}', $DurationSeconds)))))
if ($cliSummaryLines.Count -gt 0) { $summaryKvRows += $cliSummaryLines }
$summaryKvRows += ('<div class="key">Base</div><div class="value"><span id="clip_base" data-base-path="{0}">{0}</span> <button class="btn" onclick="copyText(''clip_base'')">Copy</button></div>' -f (HtmlEncode($Base)))
$summaryKvRows += ('<div class="key">Head</div><div class="value"><span id="clip_head" data-head-path="{0}">{0}</span> <button class="btn" onclick="copyText(''clip_head'')">Copy</button></div>' -f (HtmlEncode($Head)))
$summaryKvHtml = [string]::Join("`n      ", $summaryKvRows)

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
      $summaryKvHtml
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

