param(
  [string]$ResultsDir = 'tests/results',
  [int]$MaxNotices = 10,
  [switch]$AppendToStepSummary,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile($p) { if (Test-Path -LiteralPath $p -PathType Leaf) { try { Get-Content $p -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $null } } else { $null } }
function To-Arr($x) { if ($null -eq $x) { @() } elseif ($x -is [System.Array]) { @($x) } else { ,$x } }

$root = Get-Location
$handoffPath = Join-Path $root 'AGENT_HANDOFF.txt'

# Repo context
$branch = ''
try { $branch = git rev-parse --abbrev-ref HEAD 2>$null } catch {}
$headSha = ''
try { $headSha = git rev-parse HEAD 2>$null } catch {}
$repo = ''
try { $repo = gh repo view --json nameWithOwner -q .nameWithOwner 2>$null } catch {}

# Env toggles
$envs = @{}
foreach($k in @(
    'LV_SUPPRESS_UI',
    'LV_NO_ACTIVATE',
    'LV_CURSOR_RESTORE',
    'LV_IDLE_WAIT_SECONDS',
    'LV_IDLE_MAX_WAIT_SECONDS',
    'CLEAN_LV_BEFORE',
    'CLEAN_LV_AFTER',
    'CLEAN_LV_INCLUDE_COMPARE',
    'CLEAN_LVCOMPARE',
    'CLEAN_LABVIEW',
    'CLEAN_AFTER'
  )) {
  $envs[$k] = [string]([Environment]::GetEnvironmentVariable($k))
}

# Agent wait sessions (latest per id)
$waitSessions = @()
try {
  $sessRoot = Join-Path $ResultsDir '_agent'; $sessDir = Join-Path $sessRoot 'sessions'
  if (Test-Path -LiteralPath $sessDir) {
    Get-ChildItem -Path $sessDir -Directory | ForEach-Object {
      $id = $_.Name
      $last = Read-JsonFile (Join-Path $_.FullName 'wait-last.json')
      if ($last) { $waitSessions += [pscustomobject]@{ id=$id; schema=$last.schema; reason=$last.reason; elapsed=$last.elapsedSeconds; expected=$last.expectedSeconds; within=$last.withinMargin; ended=$last.endedUtc } }
    }
  }
} catch {}

# LV notices (latest few)
$noticeDir = if ($env:LV_NOTICE_DIR) { $env:LV_NOTICE_DIR } else { Join-Path $ResultsDir '_lvcompare_notice' }
$noticeItems = @()
if (Test-Path -LiteralPath $noticeDir) {
  $files = Get-ChildItem -Path $noticeDir -Filter 'notice-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxNotices
  foreach($f in $files){ $j = Read-JsonFile $f.FullName; if ($j) { $noticeItems += $j } }
}

# Rogue detector
$rogue = $null
try { $rogue = pwsh -NoLogo -NoProfile -File (Join-Path $root 'tools' 'Detect-RogueLV.ps1') -ResultsDir $ResultsDir -Quiet | ConvertFrom-Json } catch {}

# Pester summary (if any)
$pesterSummary = Read-JsonFile (Join-Path $ResultsDir 'pester-summary.json')

$ctx = [ordered]@{
  schema = 'agent-context/v1'
  generatedAt = (Get-Date).ToString('o')
  repo = $repo
  branch = $branch
  headSha = $headSha
  env = $envs
  handoffPath = (Test-Path -LiteralPath $handoffPath)
  waitSessions = $waitSessions
  notices = $noticeItems
  rogue = $rogue
  pester = if ($pesterSummary) { @{ total=$pesterSummary.total; failed=$pesterSummary.failed; errors=$pesterSummary.errors; duration_s=$pesterSummary.duration_s } } else { $null }
}

# Write files
$ctxDir = Join-Path $ResultsDir '_agent'; $ctxDir = Join-Path $ctxDir 'context'
New-Item -ItemType Directory -Force -Path $ctxDir | Out-Null
$jsonPath = Join-Path $ctxDir 'context.json'
$mdPath = Join-Path $ctxDir 'context.md'
$ctx | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8

# Compact MD summary
$md = @()
$md += '### Agent Context'
$md += "- Repo: $repo"
$md += "- Branch: $branch"
$md += "- Head: $headSha"
$md += "- Handoff present: $((Test-Path -LiteralPath $handoffPath))"
$md += ''
$md += '#### Env'
foreach($k in $envs.Keys){ $md += ('- {0} = {1}' -f $k,$envs[$k]) }
$md += ''
$md += '#### Wait Sessions'
if ($waitSessions.Count -gt 0) { foreach($s in $waitSessions){ $md += ('- {0}: {1}/{2}s within={3} ended={4}' -f $s.id,$s.elapsed,$s.expected,$s.within,$s.ended) } } else { $md += '- (none)' }
$md += ''
$md += '#### Rogue Detector'
if ($rogue) {
  $md += ('- Live: LVCompare={0} LabVIEW={1}' -f ((To-Arr $rogue.live.lvcompare) -join ','), ((To-Arr $rogue.live.labview) -join ','))
  $md += ('- Noticed: LVCompare={0} LabVIEW={1}' -f ((To-Arr $rogue.noticed.lvcompare) -join ','), ((To-Arr $rogue.noticed.labview) -join ','))
  $md += ('- Rogue: LVCompare={0} LabVIEW={1}' -f ((To-Arr $rogue.rogue.lvcompare) -join ','), ((To-Arr $rogue.rogue.labview) -join ','))
} else { $md += '- (detector unavailable)' }
$md -join "`n" | Out-File -FilePath $mdPath -Encoding utf8

if ($AppendToStepSummary -and $env:GITHUB_STEP_SUMMARY) { Get-Content -LiteralPath $mdPath -Raw | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }

if (-not $Quiet) { Write-Host "Agent context written: $jsonPath" }
Write-Output $jsonPath
