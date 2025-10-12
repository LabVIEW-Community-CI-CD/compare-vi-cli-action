#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$CasesPath = 'tests/cli-compare/cases.json',
  [string]$ResultsRoot = 'tests/results/compare-cli',
  [string]$LabVIEWCliPath,
  [switch]$PromptScaffold,
  [switch]$OpenReport,
  [switch]$AllowDiff
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function Ask-YesNo([string]$prompt,[bool]$def=$false){
  $suf = if ($def) { '[Y/n]' } else { '[y/N]' }
  while ($true) {
    $ans = Read-Host ("$prompt $suf")
    if ([string]::IsNullOrWhiteSpace($ans)) { return $def }
    $a = $ans.Trim().ToLowerInvariant()
    if ($a -in @('y','yes')) { return $true }
    if ($a -in @('n','no'))  { return $false }
  }
}

function Read-CasesInteractive(){
  Write-Host 'Enter Base/Head VI pairs. Leave Base empty to finish.' -ForegroundColor Cyan
  $cases = @()
  while ($true) {
    $base = Read-Host 'Base VI path'
    if ([string]::IsNullOrWhiteSpace($base)) { break }
    $head = Read-Host 'Head VI path'
    if ([string]::IsNullOrWhiteSpace($head)) { Write-Host 'Head required; skipping' -ForegroundColor Yellow; continue }
    $cases += [ordered]@{ base=$base; head=$head }
  }
  ,$cases
}

function Show-Cases([array]$cases){
  for ($i=0; $i -lt $cases.Count; $i++) {
    $c = $cases[$i]
    Write-Host ("[{0}] base='{1}' head='{2}'" -f ($i+1), $c.base, $c.head)
  }
}

function Parse-Selection([string]$sel,[int]$max){
  if ([string]::IsNullOrWhiteSpace($sel) -or $sel.Trim().ToLowerInvariant() -eq 'all') { return 1..$max }
  $out = New-Object System.Collections.Generic.HashSet[int]
  foreach ($part in $sel.Split(',',[System.StringSplitOptions]::RemoveEmptyEntries)){
    $p = $part.Trim()
    if ($p -match '^(\d+)-(\d+)$') {
      $a=[int]$Matches[1]; $b=[int]$Matches[2]
      if ($a -gt 0 -and $b -ge $a -and $b -le $max) { foreach ($n in $a..$b) { $out.Add($n) | Out-Null } }
    } elseif ($p -match '^(\d+)$') {
      $n=[int]$Matches[1]; if ($n -gt 0 -and $n -le $max) { $out.Add($n) | Out-Null }
    }
  }
  ,([int[]]$out)
}

function Resolve-PathSafe([string]$p){ try { return (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { return $p } }

# Ensure directories
New-Dir (Split-Path -Parent $CasesPath)
New-Dir $ResultsRoot

# Load or scaffold cases
$cases = @()
if (Test-Path -LiteralPath $CasesPath -PathType Leaf -and -not $PromptScaffold) {
  try { $cases = Get-Content -LiteralPath $CasesPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $cases = @() }
}
if (-not $cases -or $PromptScaffold) {
  $cases = Read-CasesInteractive
  if (-not $cases -or $cases.Count -eq 0) { throw 'No cases provided.' }
  ($cases | ConvertTo-Json -Depth 4) | Out-File -LiteralPath $CasesPath -Encoding utf8
  Write-Host ("Saved cases to {0}" -f (Resolve-PathSafe $CasesPath)) -ForegroundColor Green
}

Show-Cases $cases
$sel = Read-Host 'Select cases (e.g., all or 1,3-5)'
$idxs = Parse-Selection -sel $sel -max $cases.Count
if (-not $idxs -or $idxs.Count -eq 0) { throw 'Nothing selected.' }

# Configure CLI environment
$env:LVCI_COMPARE_MODE = 'labview-cli'
if (-not $env:LVCI_CLI_FORMAT) { $env:LVCI_CLI_FORMAT = 'XML' }
if ($LabVIEWCliPath) { $env:LABVIEW_CLI_PATH = (Resolve-PathSafe $LabVIEWCliPath) }

. (Join-Path $PSScriptRoot '..' 'scripts' 'CompareVI.ps1')

$fail = $false
$summary = @()
foreach ($i in $idxs | Sort-Object) {
  $case = $cases[$i-1]
  $baseAbs = Resolve-PathSafe $case.base
  $headAbs = Resolve-PathSafe $case.head
  $nunitPath = Join-Path $ResultsRoot ("results-nunit-case{0}.xml" -f $i)
  $execPath  = Join-Path $ResultsRoot ("compare-exec-case{0}.json" -f $i)
  $env:LVCI_CLI_NUNIT_PATH = $nunitPath
  try {
    $res = Invoke-CompareVI -Base $baseAbs -Head $headAbs -FailOnDiff:$false -CompareExecJsonPath $execPath
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Assert-NUnitSuccess.ps1') -ResultsPath $nunitPath -Context ("Case {0}" -f $i) | Out-Null
    $summary += [ordered]@{ case=$i; base=$baseAbs; head=$headAbs; nunit=$nunitPath; exit=$res.ExitCode; diff=$res.Diff }
    if ($OpenReport) {
      try {
        $rep = $res.ReportPath
        if ($rep -and (Test-Path -LiteralPath $rep -PathType Leaf)) { Write-Host "Report: $(Resolve-PathSafe $rep)" -ForegroundColor DarkCyan }
      } catch {}
    }
    if (-not $AllowDiff -and $res.Diff) { $fail = $true }
  } catch {
    Write-Error $_
    $summary += [ordered]@{ case=$i; base=$baseAbs; head=$headAbs; nunit=$nunitPath; exit='err'; diff=$null }
    $fail = $true
  }
}

Write-Host ''
Write-Host 'CLI Compare run summary:' -ForegroundColor Cyan
foreach ($row in $summary) {
  Write-Host ("- case={0} exit={1} diff={2} nunit={3}" -f $row.case, $row.exit, $row.diff, (Resolve-PathSafe $row.nunit))
}

if ($fail) { exit 1 } else { exit 0 }

