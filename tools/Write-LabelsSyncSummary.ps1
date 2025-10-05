param(
  [string]$ConfigPath = '.github/labels.yml',
  [switch]$FailOnMissing
)

$ErrorActionPreference = 'Stop'

function Read-ConfigLabels {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Label config not found: $Path" }
  $lines = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop -TotalCount 10000 -ReadCount 0
  $lines = $lines -split "`r?`n"
  $labels = @()
  $current = $null
  foreach ($line in $lines) {
    if ($line -match '^\s*-\s*name:\s*"?([^"#]+)"?') {
      if ($current) { $labels += $current }
      $n = ($Matches[1]).Trim()
      $current = [ordered]@{ name=$n; color=$null; description=$null }
      continue
    }
    if (-not $current) { continue }
    if ($line -match '^\s*color:\s*"?([0-9A-Fa-f]{3,6})"?') {
      $current.color = ($Matches[1]).ToUpperInvariant()
      continue
    }
    if ($line -match '^\s*description:\s*"?(.+?)"?$') {
      $current.description = $Matches[1]
      continue
    }
  }
  if ($current) { $labels += $current }
  return ,$labels
}

function Get-LiveLabels {
  $repo = $env:GITHUB_REPOSITORY
  if (-not $repo) { throw 'GITHUB_REPOSITORY not set' }
  $owner,$name = $repo.Split('/')
  $token = $env:GITHUB_TOKEN
  if (-not $token) { throw 'GITHUB_TOKEN not available' }
  $api = "https://api.github.com/repos/$owner/$name/labels"
  $hdr = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28' }
  $page = 1; $size = 100; $maxPages = 10
  $labels = @()
  while ($true) {
    $uri = "$api?per_page=$size&page=$page"
    try {
      $res = Invoke-RestMethod -Method Get -Uri $uri -Headers $hdr -ErrorAction Stop
    } catch {
      throw "Failed to fetch labels: $($_.Exception.Message)"
    }
    if (-not $res) { break }
    foreach ($l in $res) { $labels += [ordered]@{ name=[string]$l.name; color=([string]$l.color).ToUpperInvariant() } }
    if (@($res).Count -lt $size -or $page -ge $maxPages) { break }
    $page++
  }
  return ,$labels
}

try {
  $config = Read-ConfigLabels -Path $ConfigPath
} catch {
  Write-Host "::notice::Labels sync summary skipped: $($_.Exception.Message)"
  exit 0
}

try {
  $live = Get-LiveLabels
} catch {
  Write-Host "::notice::Labels sync summary skipped (API): $($_.Exception.Message)"
  exit 0
}

$configByName = @{}
foreach ($c in $config) { $configByName[$c.name] = $c }
$liveByName = @{}
foreach ($l in $live) { $liveByName[$l.name] = $l }

$configNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($c in $config) { [void]$configNames.Add($c.name) }
$liveNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($l in $live) { [void]$liveNames.Add($l.name) }

$missing = @(); foreach ($n in $configNames) { if (-not $liveNames.Contains($n)) { $missing += $n } }
$extra   = @(); foreach ($n in $liveNames)   { if (-not $configNames.Contains($n)) { $extra   += $n } }
$colorDiff = @()
foreach ($n in $configNames) {
  if ($liveByName.ContainsKey($n)) {
    $c = $configByName[$n]
    $l = $liveByName[$n]
    if ($c.color -and $l.color -and $c.color -ne $l.color) {
      $colorDiff += [ordered]@{ name=$n; config=$c.color; live=$l.color }
    }
  }
}

$lines = @('### Labels Sync Summary','')
$lines += ('- Config labels: {0} → {1}' -f $config.Count, ((@($config | ForEach-Object name) -join ', ') -replace '\s+$',''))
$lines += ('- Live labels: {0} → {1}'   -f $live.Count,   ((@($live   | ForEach-Object name) -join ', ') -replace '\s+$',''))
if ($missing.Count -gt 0) { $lines += ('- Missing (in repo): ' + ($missing -join ', ')) } else { $lines += '- Missing: (none)' }
if ($extra.Count   -gt 0) { $lines += ('- Extra (not in config): ' + ($extra -join ', ')) } else { $lines += '- Extra: (none)' }
if ($colorDiff.Count -gt 0) {
  $lines += '- Color differences:'
  foreach ($d in $colorDiff) { $lines += ('  - {0}: config={1} live={2}' -f $d.name,$d.config,$d.live) }
} else { $lines += '- Color differences: (none)' }

$lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8

# Optionally fail on main when missing labels exist
$isMain = ($env:GITHUB_REF -eq 'refs/heads/main')
if ($FailOnMissing -and $isMain -and $missing.Count -gt 0) {
  Write-Host '::error::Labels missing on main branch. See Labels Sync Summary.'
  exit 22
}
exit 0
