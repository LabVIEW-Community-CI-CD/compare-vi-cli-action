[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [int]$Top = 5,
  [switch]$PassThru,
  [ValidateSet('quiet','concise','normal','detailed','debug')][string]$ConsoleLevel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failurePayloadTool = Join-Path $PSScriptRoot 'PesterFailurePayload.ps1'
if (Test-Path -LiteralPath $failurePayloadTool -PathType Leaf) {
  . $failurePayloadTool
}

$repoRoot = (Resolve-Path '.').Path
$uxModule = Join-Path $repoRoot 'tools' 'ConsoleUx.psm1'
if (Test-Path -LiteralPath $uxModule -PathType Leaf) {
  try { Import-Module $uxModule -Force -ErrorAction Stop } catch {}
}

function Get-Dx {
  param([string]$Override)
  try { return (Get-DxLevel -Override $Override) } catch { return 'normal' }
}

$dx = Get-Dx $ConsoleLevel
if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
  if ($PassThru) { return @() }
  if ($dx -ne 'quiet') { Write-Warning "Results directory not found: $ResultsDir" }
  return
}

$items = @()
$failJson = Join-Path $ResultsDir 'pester-failures.json'
$nunitXml = Join-Path $ResultsDir 'pester-results.xml'
$failurePayloadInfo = $null

if (Test-Path -LiteralPath $failJson -PathType Leaf) {
  $failurePayloadInfo = Read-PesterFailurePayloadFile -PathValue $failJson
  if ($failurePayloadInfo.parseStatus -eq 'parsed') {
    foreach ($f in (Get-PesterFailureEntries -FailurePayload $failurePayloadInfo.payload)) {
      $nameProp = if ($f.PSObject.Properties['name']) { [string]$f.name } else { '' }
      $fileProp = if ($f.PSObject.Properties['file']) { [string]$f.file } else { '' }
      $lineProp = if ($f.PSObject.Properties['line']) { [string]$f.line } else { '' }
      $messageProp = if ($f.PSObject.Properties['message']) { [string]$f.message } else { '' }
      $items += [pscustomobject]@{
        name    = $nameProp
        file    = $fileProp
        line    = $lineProp
        message = $messageProp
      }
    }
  } elseif ($dx -ne 'quiet') {
    Write-Warning ("Failed to parse ${failJson}: {0}" -f $failurePayloadInfo.parseError)
  }
} elseif (Test-Path -LiteralPath $nunitXml -PathType Leaf) {
  try {
    [xml]$xml = Get-Content -LiteralPath $nunitXml -Raw
    $nodes = $xml.SelectNodes('//test-case[failure]')
    foreach ($n in $nodes) {
      $stack = $n.failure.'stack-trace'
      $file = ''
      $line = ''
      if ($stack) {
        $m = [regex]::Match($stack,'(?m)([A-Z]:\\[^\r\n]+?):line\s+(\d+)')
        if ($m.Success) { $file = $m.Groups[1].Value; $line = $m.Groups[2].Value }
      }
      $nameProp = if ($n.PSObject.Properties['name']) { [string]$n.name } else { '' }
      $messageProp = ''
      if ($n.failure -and $n.failure.PSObject.Properties['message']) { $messageProp = [string]$n.failure.message }
      $items += [pscustomobject]@{
        name    = $nameProp
        file    = $file
        line    = $line
        message = $messageProp
      }
    }
  } catch {
    if ($dx -ne 'quiet') { Write-Warning "Failed to parse ${nunitXml}: $_" }
  }
}

if (-not $items -or $items.Count -eq 0) {
  if ($dx -ne 'quiet') {
    $summaryPath = Join-Path $ResultsDir 'pester-summary.json'
    $summary = $null
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
      try { $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
    $detailState = Get-PesterFailureDetailState -FailurePayload $(if ($failurePayloadInfo) { $failurePayloadInfo.payload } else { $null }) -Summary $summary
    if ($detailState.detailStatus -eq 'unavailable') {
      $reasonSuffix = if ($detailState.unavailableReason) { " reason=$($detailState.unavailableReason)" } else { '' }
      Write-Host ("[dx] top-failures unavailable{0}" -f $reasonSuffix)
    } else {
      Write-Host '[dx] top-failures none'
    }
  }
  if ($PassThru) { return @() }
  return
}

$take = [Math]::Min($Top, $items.Count)
if ($dx -ne 'quiet') { Write-Host "[dx] top-failures count=$take" }
for ($i = 0; $i -lt $take; $i++) {
  $it = $items[$i]
  $msg = if ($it.message) { ($it.message -split "`n")[0].Trim() } else { '' }
  $loc = ''
  if ($it.file) {
    $loc = $it.file
    if ($it.line) { $loc = "{0}:{1}" -f $loc,$it.line }
  }
  $kv = @{}
  if ($it.name) { $kv.name = $it.name }
  if ($loc) { $kv.location = $loc }
  if ($msg) { $kv.message = $msg }
  if ($kv.Count -eq 0) { $kv.message = 'Failure' }
  if (Get-Command Write-DxKV -ErrorAction SilentlyContinue) {
    Write-DxKV -Data $kv -Prefix '[dx] fail' -ConsoleLevel $dx
  } else {
    $parts = $kv.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key,$_.Value }
    Write-Host ("[dx] fail {0}" -f ($parts -join ' '))
  }
}

if ($PassThru) { return $items }
