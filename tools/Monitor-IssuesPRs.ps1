#Requires -Version 7.0
<#!
.SYNOPSIS
  Summarize open issues and PRs and emit lightweight suggestions.
.DESCRIPTION
  Uses gh CLI to list open issues/PRs. Prints tables and a short
  suggestions section (e.g., missing labels, missing closing keywords,
  stale items). Optionally writes a Markdown summary file.
.PARAMETER Repo
  owner/name. Inferred from git remote when omitted.
.PARAMETER Limit
  Max items to fetch for each list. Default: 50.
.PARAMETER StaleDays
  Consider items stale after N days without update. Default: 14.
.PARAMETER OutputPath
  Optional Markdown output path for the summary.
.PARAMETER Json
  Also print raw JSON blobs for machine use.
.PARAMETER Watch
  Re-run every -IntervalSeconds seconds until Ctrl+C.
.PARAMETER IntervalSeconds
  Interval for -Watch. Default: 60.
#>
[CmdletBinding()] param(
  [string] $Repo,
  [int] $Limit = 50,
  [int] $StaleDays = 14,
  [string] $OutputPath,
  [switch] $Json,
  [switch] $Watch,
  [int] $IntervalSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoFromGit {
  try {
    $u = git config --get remote.origin.url 2>$null
    if ($u -match 'github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$') { return "{0}/{1}" -f $Matches[1], $Matches[2] }
  } catch {}
  throw 'Cannot resolve repo from git remote; provide -Repo owner/name.'
}

function Ensure-GhAuth { gh auth status -h github.com | Out-Null }

function Once {
  param([string] $Repo)
  $now = Get-Date
  $issues = gh issue list -R $Repo --state open --limit $Limit --json number,title,labels,assignees,updatedAt,url 2>$null | ConvertFrom-Json
  $prs    = gh pr list    -R $Repo --state open --limit $Limit --json number,title,labels,updatedAt,headRefName,url 2>$null | ConvertFrom-Json
  if ($Json) {
    [pscustomobject]@{ repo=$Repo; generated=$now; issues=$issues; prs=$prs } | ConvertTo-Json -Depth 6 | Write-Output
  }
  $out = @()
  $out += "### Open PRs ($($prs.Count))"
  foreach ($p in ($prs | Sort-Object updatedAt -Descending)) {
    $lbl = ($p.labels | ForEach-Object name) -join ','
    $age = [int]([TimeSpan]::FromTicks(($now - (Get-Date $p.updatedAt)).Ticks).TotalDays)
    $out += ("- PR #{0} [{1}]({2}) · {3}d · labels: {4}" -f $p.number,$p.title,$p.url,$age,$lbl)
  }
  $out += ""
  $out += "### Open Issues ($($issues.Count))"
  foreach ($i in ($issues | Sort-Object updatedAt -Descending)) {
    $lbl = ($i.labels | ForEach-Object name) -join ','
    $age = [int]([TimeSpan]::FromTicks(($now - (Get-Date $i.updatedAt)).Ticks).TotalDays)
    $out += ("- Issue #{0} [{1}]({2}) · {3}d · labels: {4}" -f $i.number,$i.title,$i.url,$age,$lbl)
  }
  $out += ""
  $out += "### Suggestions"
  $stalePr = $prs | Where-Object { ((Get-Date) - (Get-Date $_.updatedAt)).TotalDays -ge $StaleDays }
  foreach ($p in $stalePr) { $out += ("- Consider ping or closing stale PR #{0} ({1})" -f $p.number,$p.headRefName) }
  $noLabels = $prs | Where-Object { -not $_.labels -or $_.labels.Count -eq 0 }
  foreach ($p in $noLabels) { $out += ("- Add labels to PR #{0} ({1}) for routing" -f $p.number,$p.headRefName) }
  $missingCloses = @()
  foreach ($p in $prs) {
    try {
      $body = gh pr view -R $Repo $p.number --json body 2>$null | ConvertFrom-Json
      if (-not ($body.body -match '(?mi)^Closes\s+#\d+')) { $missingCloses += $p }
    } catch {}
  }
  foreach ($p in $missingCloses) { $out += ("- Add 'Closes #<issue>' to PR #{0} to auto-close tracking issue on merge" -f $p.number) }
  if ($out[-1] -eq '### Suggestions') { $out += '- None' }
  $text = ($out -join "`n")
  $text | Write-Output
  if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath; if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $text -Encoding UTF8
  }
}

Ensure-GhAuth
if (-not $Repo) { $Repo = Resolve-RepoFromGit }
do { Once -Repo $Repo; if ($Watch) { Start-Sleep -Seconds $IntervalSeconds } } while ($Watch)

