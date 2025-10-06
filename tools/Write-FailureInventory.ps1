param(
  [string]$ResultsDir = 'tests/results',
  [string]$SummaryPath,
  [switch]$AppendToStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Line([string]$text){
  if (-not (Get-Variable -Name _lines -Scope Script -ErrorAction SilentlyContinue)) {
    $script:_lines = [System.Collections.Generic.List[string]]::new()
  }
  $script:_lines.Add($text) | Out-Null
}

function Flush([string]$path){
  if (-not $script:_lines) { return }
  ($script:_lines -join [Environment]::NewLine) | Set-Content -LiteralPath $path -Encoding utf8
  if ($AppendToStepSummary -and $env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ([Environment]::NewLine + ($script:_lines -join [Environment]::NewLine)) -Encoding utf8
  }
}

if (-not $SummaryPath) { $SummaryPath = Join-Path $ResultsDir 'failure-inventory.md' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SummaryPath) | Out-Null

$xml = Join-Path $ResultsDir 'pester-results.xml'
$failJson = Join-Path $ResultsDir 'pester-failures.json'

$failures = @()
try {
  if (Test-Path -LiteralPath $xml) {
    [xml]$doc = Get-Content -LiteralPath $xml -Raw
    $cases = @($doc.'test-results'.'test-suite'.'results'.'test-case')
    foreach ($tc in $cases) {
      $res = [string]$tc.result
      if ($res -ieq 'Failed' -or $res -ieq 'Error') {
        $name = [string]$tc.name
        $file = [string]$tc.file
        $msg = $null
        if ($tc.'failure' -and $tc.'failure'.message) { $msg = [string]$tc.'failure'.message }
        elseif ($tc.'reason' -and $tc.'reason'.message) { $msg = [string]$tc.'reason'.message }
        $failures += [pscustomobject]@{ name=$name; file=$file; message=$msg; result=$res }
      }
    }
  }
} catch { }

if ($failures.Count -eq 0 -and (Test-Path -LiteralPath $failJson)) {
  try {
    $fj = Get-Content -LiteralPath $failJson -Raw | ConvertFrom-Json
    if ($fj -and $fj.results) {
      foreach ($r in $fj.results) {
        if ($r.result -eq 'Failed') { $failures += [pscustomobject]@{ name=$r.Name; file=$r.Path; message=$r.ErrorRecord; result='Failed' } }
      }
    }
  } catch { }
}

Add-Line '### Failure Inventory'
if ($failures.Count -eq 0) {
  Add-Line '- No failures found (or results missing)'
  Write-Host ("Failure inventory path: {0}" -f $SummaryPath)
  Flush -path $SummaryPath
  exit 0
}

Add-Line ("- Total failures: {0}" -f $failures.Count)

$byFile = $failures | Group-Object file | Sort-Object Count -Descending
Add-Line ''
Add-Line '| File | Count |'
Add-Line '|------|-------|'
foreach ($g in $byFile) { $fn = if ($g.Name) { $g.Name } else { '(unknown)' }; Add-Line ("| {0} | {1} |" -f $fn, $g.Count) }

# Top messages (first line of message)
$normalized = $failures | ForEach-Object {
  $msg = [string]$_.message
  if (-not $msg) { $msg = $_.result }
  else { $nl = $msg.IndexOf("`n"); if ($nl -gt 0) { $msg = $msg.Substring(0,$nl) } }
  [pscustomobject]@{ key=$msg }
}
$byMsg = $normalized | Group-Object key | Sort-Object Count -Descending | Select-Object -First 10
Add-Line ''
Add-Line 'Top messages:'
foreach ($m in $byMsg) { Add-Line ("- {0} (x{1})" -f $m.Name, $m.Count) }

Write-Host ("Failure inventory path: {0}" -f $SummaryPath)
Flush -path $SummaryPath

