Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Developer utility to preview LVCompare argument tokenization without invoking LVCompare.exe.
.DESCRIPTION
  Accepts an arg specification via -Args (string or string[]) and prints:
  - Raw input
  - Tokenized list (comma/whitespace with quotes respected)
  - Normalized tokens where combined tokens and -flag=value are split into [flag,value]

  This script does NOT spawn LVCompare or any external processes.
.EXAMPLE
  pwsh -File scripts/Debug-Args.ps1 -Args "-nobdcosm -nofppos -noattr '--log C:\\a b\\z.txt' -lvpath=C:\\X\\LabVIEW.exe"
#>
param(
  [Parameter(Mandatory=$true)]
  [Alias('Arg','A')]
  [object]$Args
)

# Import shared tokenization module
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force

function Convert-ArgTokenList([string[]]$tokens) {
  $out = @()
  foreach ($t in $tokens) {
    if ($null -eq $t) { continue }
    $tok = $t.Trim()
    if ($tok.StartsWith('-') -and $tok.Contains('=')) {
      $eq = $tok.IndexOf('=')
      if ($eq -gt 0) {
        $flag = $tok.Substring(0,$eq)
        $val = $tok.Substring($eq+1)
        if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1,$val.Length-2) }
        elseif ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Substring(1,$val.Length-2) }
        if ($flag) { $out += $flag }
        if ($val) { $out += $val }
        continue
      }
    }
    if ($tok.StartsWith('-') -and $tok -match '\s+') {
      $idx = $tok.IndexOf(' ')
      if ($idx -gt 0) {
        $flag = $tok.Substring(0,$idx)
        $val  = $tok.Substring($idx+1)
        if ($flag) { $out += $flag }
        if ($val)  { $out += $val }
        continue
      }
    }
    $out += $tok
  }
  return $out
}

function Split-ArgSpec([object]$value) {
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) {
    $out = @()
    foreach ($v in $value) {
      $t = [string]$v
      if ($null -ne $t) { $t = $t.Trim() }
      if (-not [string]::IsNullOrWhiteSpace($t)) {
        if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) { $t = $t.Substring(1, $t.Length-2) }
        if ($t -ne '') { $out += $t }
      }
    }
    return $out
  }
  $s = [string]$value
  if ($s -match '^\s*$') { return @() }
  $pattern = Get-LVCompareArgTokenPattern
  $mList = [regex]::Matches($s, $pattern)
  $list = @()
  foreach ($m in $mList) {
    $t = $m.Value.Trim()
    if ($t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length-2) }
    elseif ($t.StartsWith("'") -and $t.EndsWith("'")) { $t = $t.Substring(1, $t.Length-2) }
    if ($t -ne '') { $list += $t }
  }
  return $list
}

function Convert-ForDisplay {
  param([object[]]$arr)
  return @($arr | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_ } })
}

$raw = $Args
$tokens = Split-ArgSpec -value $raw
$normalized = Convert-ArgTokenList -tokens $tokens

Write-Host '=== Debug-Args Preview ===' -ForegroundColor Cyan
Write-Host ('Raw:        {0}' -f ($raw -join ' '))
Write-Host ('Tokens:     {0}' -f ((Convert-ForDisplay $tokens) -join ' | '))
Write-Host ('Normalized: {0}' -f ((Convert-ForDisplay $normalized) -join ' | '))

Set-Variable -Name DEBUG_ARGS_TOKENS -Value $tokens -Scope Script -Force
Set-Variable -Name DEBUG_ARGS_NORMALIZED -Value $normalized -Scope Script -Force
Write-Host 'Exported $DEBUG_ARGS_TOKENS and $DEBUG_ARGS_NORMALIZED in script scope.' -ForegroundColor Gray
