#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Plain,
  [switch]$CacheOnly,
  [switch]$NoCacheUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path '.').Path
$cachePath = Join-Path $repoRoot '.agent_priority_cache.json'

function Write-OutputObject {
  param([pscustomobject]$Priority)

  if ($Plain) {
    if ($null -ne $Priority.number -and $Priority.number -ne 0) {
      $title = if ($Priority.title) { $Priority.title } else { '(no title)' }
      Write-Output ("#{0} — {1}" -f $Priority.number, $title)
    } else {
      Write-Output 'Standing priority not set'
    }
  } else {
    $Priority | ConvertTo-Json -Depth 5 | Write-Output
  }
}

function Normalize-PriorityObject {
  param(
    [nullable[int]]$Number,
    [string]$Title,
    [string]$Url,
    [string]$Source
  )

  $cleanTitle = if ($Title) { $Title.Trim() } else { $null }
  $cleanUrl = if ($Url) { $Url.Trim() } else { $null }
  if ($cleanUrl -and -not ($cleanUrl -match '^https?://')) { $cleanUrl = $null }

  return [pscustomobject]@{
    number = $Number
    title = $cleanTitle
    url = $cleanUrl
    source = $Source
    retrievedAtUtc = (Get-Date -AsUTC).ToString('o')
  }
}

function Parse-OverrideValue {
  param([string]$Override)

  if (-not $Override) { return $null }

  $trimmed = $Override.Trim()
  if (-not $trimmed) { return $null }

  # JSON override
  if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
    try {
      $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
      if ($obj -is [System.Collections.IEnumerable]) { $obj = @($obj)[0] }
      if (-not $obj) { return $null }
      $num = $null
      if ($obj.PSObject.Properties.Name -contains 'number') {
        [int]$dummy = 0
        if ([int]::TryParse([string]$obj.number, [ref]$dummy)) { $num = $dummy }
      }
      $title = if ($obj.PSObject.Properties.Name -contains 'title') { [string]$obj.title } else { $null }
      $url = if ($obj.PSObject.Properties.Name -contains 'url') { [string]$obj.url } else { $null }
      return Normalize-PriorityObject -Number $num -Title $title -Url $url -Source 'override'
    } catch {
      return $null
    }
  }

  $parts = $trimmed -split '\|', 3
  $rawNumber = $parts[0].Trim()
  if (-not [int]::TryParse($rawNumber, [ref]([int]$null))) { return $null }
  $number = [int]$rawNumber
  $title = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1].Trim() } else { $null }
  $url = if ($parts.Count -gt 2 -and $parts[2]) { $parts[2].Trim() } else { $null }
  return Normalize-PriorityObject -Number $number -Title $title -Url $url -Source 'override'
}

function Try-LoadCache {
  if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }
  try {
    $cacheObj = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($cacheObj) {
      return Normalize-PriorityObject -Number $cacheObj.number -Title $cacheObj.title -Url $cacheObj.url -Source 'cache'
    }
  } catch {}
  return $null
}

function Save-Cache {
  param([pscustomobject]$Priority)
  if ($NoCacheUpdate) { return }
  try {
    $payload = [ordered]@{
      number = $Priority.number
      title = $Priority.title
      url = $Priority.url
      cachedAtUtc = (Get-Date -AsUTC).ToString('o')
    }
    $payload | ConvertTo-Json -Depth 4 | Out-File -FilePath $cachePath -Encoding utf8
  } catch {}
}

function Try-GitHubPriority {
  $gh = $null
  try { $gh = Get-Command gh -ErrorAction Stop } catch { return $null }
  if (-not $gh) { return $null }

  $args = @('issue','list','--label','standing-priority','--state','open','--limit','1','--json','number,title,url')
  try {
    $json = & $gh.Source $args 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $parsed = $json | ConvertFrom-Json -ErrorAction Stop
    if ($parsed -is [System.Collections.IEnumerable]) {
      $parsed = @($parsed)
      if ($parsed.Count -eq 0) { return $null }
      $parsed = $parsed[0]
    }
    if (-not $parsed) { return $null }
    $num = $null
    if ($parsed.PSObject.Properties.Name -contains 'number') {
      [int]$tmp = 0
      if ([int]::TryParse([string]$parsed.number, [ref]$tmp)) { $num = $tmp }
    }
    $title = if ($parsed.PSObject.Properties.Name -contains 'title') { [string]$parsed.title } else { $null }
    $url = if ($parsed.PSObject.Properties.Name -contains 'url') { [string]$parsed.url } else { $null }
    return Normalize-PriorityObject -Number $num -Title $title -Url $url -Source 'github'
  } catch {
    return $null
  }
}

$priority = $null

$overrideValue = $env:AGENT_PRIORITY_OVERRIDE
if ($overrideValue) {
  $priority = Parse-OverrideValue -Override $overrideValue
}

if (-not $priority -and -not $CacheOnly) {
  $priority = Try-GitHubPriority
  if ($priority) { Save-Cache -Priority $priority }
}

if (-not $priority) {
  $priority = Try-LoadCache
}

if (-not $priority) {
  throw "Standing priority not found. Label 'standing-priority' may be missing or unsecured, and no override is set."
}

Write-OutputObject -Priority $priority
