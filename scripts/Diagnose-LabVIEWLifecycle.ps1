param(
  [string]$Base = (Resolve-Path './VI1.vi' -ErrorAction SilentlyContinue).Path,
  [string]$Head = (Resolve-Path './VI2.vi' -ErrorAction SilentlyContinue).Path,
  [string]$LvCompareArgs = '',
  [int]$DelayAfterExitSeconds = 3,
  [string]$OutputJson = 'labview-lifecycle-diagnose.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProcSnapshot {
  param([string[]]$Names)
  $list = @()
  foreach ($n in $Names) {
    try {
      $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
      foreach ($p in @($procs)) {
        $path = $null; $start = $null
        try { $path = $p.Path } catch { $path = $null }
        try { $start = $p.StartTime } catch { $start = $null }
        $list += [pscustomobject]@{ Name=$p.ProcessName; Id=$p.Id; Path=$path; StartTime=$start }
      }
    } catch {}
  }
  return ,$list
}

function Write-Json([object]$obj,[string]$path) {
  $json = $obj | ConvertTo-Json -Depth 6
  Set-Content -Path $path -Value $json -Encoding utf8
}

if (-not (Test-Path -LiteralPath $Base)) { throw "Base VI not found: $Base" }
if (-not (Test-Path -LiteralPath $Head)) { throw "Head VI not found: $Head" }

$pre = Get-ProcSnapshot -Names @('LabVIEW','LVCompare')
$preLabVIEW = @($pre | Where-Object Name -eq 'LabVIEW').Count
$preLVCompare = @($pre | Where-Object Name -eq 'LVCompare').Count
Write-Host ("[Diag] Pre counts: LabVIEW={0} LVCompare={1}" -f $preLabVIEW, $preLVCompare) -ForegroundColor DarkCyan

$invokeStarted = Get-Date
try {
  $compare = Join-Path $PSScriptRoot 'CompareVI.ps1'
  if (-not (Test-Path -LiteralPath $compare)) { $compare = (Resolve-Path (Join-Path $PSScriptRoot 'CompareVI.ps1')).Path }
  pwsh -NoLogo -NoProfile -File $compare -Base $Base -Head $Head -LvCompareArgs $LvCompareArgs -FailOnDiff:$false | Out-Null
} catch {
  Write-Host "[Diag] Compare run threw: $($_.Exception.Message)" -ForegroundColor Yellow
}

Start-Sleep -Seconds ([Math]::Max(1,$DelayAfterExitSeconds))

$post1 = Get-ProcSnapshot -Names @('LabVIEW','LVCompare')
Start-Sleep -Milliseconds 500
$post2 = Get-ProcSnapshot -Names @('LabVIEW','LVCompare')

function Get-NewLabVIEWCount([DateTime]$since,[object[]]$snap) {
  @($snap | Where-Object { $_.Name -eq 'LabVIEW' -and $_.StartTime -and $_.StartTime -ge $since }).Count
}

$new1 = Get-NewLabVIEWCount -since $invokeStarted -snap $post1
$new2 = Get-NewLabVIEWCount -since $invokeStarted -snap $post2
$lvcompareLeft = (@($post1 | Where-Object Name -eq 'LVCompare').Count -gt 0) -or (@($post2 | Where-Object Name -eq 'LVCompare').Count -gt 0)
$suspectedLeak = ($new1 -gt 0 -and $new2 -gt 0) -or $lvcompareLeft

$canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
$preLabVIEWPids = @($pre | Where-Object Name -eq 'LabVIEW' | Select-Object -ExpandProperty Id)
$postLabVIEWPids = @($post2 | Where-Object Name -eq 'LabVIEW' | Select-Object -ExpandProperty Id)
$newLabVIEWPids = @($postLabVIEWPids | Where-Object { $preLabVIEWPids -notcontains $_ })
$report = [pscustomobject]@{
  schema = 'labview-lifecycle-diagnose-v1'
  startedAt = $invokeStarted.ToString('o')
  base = (Resolve-Path $Base).Path
  head = (Resolve-Path $Head).Path
  lvCompareArgs = $LvCompareArgs
  canonicalCli = if (Test-Path -LiteralPath $canonical -PathType Leaf) { $canonical } else { $null }
  pre = $pre
  post1 = $post1
  post2 = $post2
  newLabVIEWAfterRun = @{ post1 = $new1; post2 = $new2 }
  newLabVIEWPids = $newLabVIEWPids
  lvComparePresentAfterRun = $lvcompareLeft
  suspectedLeak = $suspectedLeak
}

Write-Json $report $OutputJson
Write-Host ("[Diag] Post new LabVIEW counts since start: post1={0} post2={1}; LVCompare present after run={2}; suspectedLeak={3}" -f $new1,$new2,$lvcompareLeft,$suspectedLeak) -ForegroundColor Cyan
Write-Host ("[Diag] Wrote report: {0}" -f (Resolve-Path $OutputJson).Path) -ForegroundColor Gray
