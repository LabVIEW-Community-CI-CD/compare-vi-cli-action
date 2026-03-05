#Requires -Version 7.0

param(
  [string[]]$VipPath,
  [string]$ManifestPath,
  [string]$ResultsRoot,
  [hashtable]$VersionInfo,
  [switch]$RequireVip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestJson = $null

function Convert-ToOrderedObject {
  param([System.Collections.IDictionary]$Table)
  return [pscustomobject]$Table
}

if ($ManifestPath) {
  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest not found at '$ManifestPath'."
  }
  $manifestJson = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 6
}

if (-not $VipPath -or $VipPath.Count -eq 0) {
  if ($manifestJson) {
    $VipPath = @($manifestJson.artifacts | Where-Object { $_.kind -eq 'vip' } | ForEach-Object { $_.path })
  }
}

if (-not $ResultsRoot) {
  if ($ManifestPath) {
    $ResultsRoot = Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath)
  } else {
    $ResultsRoot = Join-Path (Get-Location) 'package-smoke'
  }
}

$ResultsRoot = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Path $ResultsRoot -Force)).Path
$summaryPath = Join-Path $ResultsRoot 'package-smoke-summary.json'

$vipCandidates = @()
if ($VipPath) {
  foreach ($candidate in $VipPath) {
    if ($candidate) {
      $vipCandidates += $candidate
    }
  }
}

if ($vipCandidates.Count -eq 0) {
  if ($RequireVip.IsPresent) {
    throw 'No VI Package artifacts were supplied for smoke testing.'
  }

  $skippedSummary = [ordered]@{
    schema      = 'icon-editor/package-smoke@v1'
    generatedAt = (Get-Date).ToString('o')
    status      = 'skipped'
    reason      = 'No VI Package artifacts available.'
    vipCount    = 0
    items       = @()
  }

  $skippedObj = Convert-ToOrderedObject $skippedSummary
  $skippedObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
  return $skippedObj
}

try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
} catch {
  # Assembly might already be loaded; ignore.
}

$items = @()
$overallStatus = 'ok'

foreach ($vip in $vipCandidates) {
  $item = [ordered]@{
    vipPath = $vip
    status  = $null
    checks  = [ordered]@{
      hasLvIconX86 = $false
      hasLvIconX64 = $false
      lvlibpCount  = 0
      versionMatch = $null
    }
  }

  if (-not (Test-Path -LiteralPath $vip -PathType Leaf)) {
    $item.status = 'missing'
    $overallStatus = 'fail'
    $items += Convert-ToOrderedObject $item
    continue
  }

  $resolvedVip = (Resolve-Path -LiteralPath $vip).Path
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedVip)
    $entries = @($zip.Entries)
    $item.checks.lvlibpCount = @($entries | Where-Object { $_.FullName -match '\.lvlibp$' }).Count
    $item.checks.hasLvIconX86 = [bool]($entries | Where-Object { $_.FullName -match 'lv_icon_x86\.lvlibp$' })
    $item.checks.hasLvIconX64 = [bool]($entries | Where-Object { $_.FullName -match 'lv_icon_x64\.lvlibp$' })

    $buildEntry = $entries | Where-Object { $_.FullName -match '^support/.*/build\.txt$' -or $_.FullName -match '^support/build\.txt$' } | Select-Object -First 1
    $buildContent = $null
    if ($buildEntry) {
      $reader = New-Object System.IO.StreamReader($buildEntry.Open())
      try {
        $buildContent = $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
    }

    if ($VersionInfo) {
      $versionDict = [System.Collections.IDictionary]$VersionInfo
      $major = if ($versionDict.Contains('major')) { $versionDict['major'] } else { 0 }
      $minor = if ($versionDict.Contains('minor')) { $versionDict['minor'] } else { 0 }
      $patch = if ($versionDict.Contains('patch')) { $versionDict['patch'] } else { 0 }
      $build = if ($versionDict.Contains('build')) { $versionDict['build'] } else { 0 }
      $expectedVersion = '{0}.{1}.{2}.{3}' -f $major, $minor, $patch, $build
      if ($buildContent) {
        $item.checks.versionMatch = $buildContent -match [Regex]::Escape($expectedVersion)
      } else {
        $item.checks.versionMatch = $null
      }
    }

    if ($item.checks.hasLvIconX86 -and $item.checks.hasLvIconX64) {
      $item.status = 'ok'
    } else {
      $item.status = 'fail'
      $overallStatus = 'fail'
    }
  } catch {
    $item.status = 'error'
    $item | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message
    $overallStatus = 'fail'
  } finally {
    if ($zip) {
      $zip.Dispose()
    }
  }

  $items += Convert-ToOrderedObject $item
}

$summary = [ordered]@{
  schema      = 'icon-editor/package-smoke@v1'
  generatedAt = (Get-Date).ToString('o')
  status      = $overallStatus
  vipCount    = $items.Count
  items       = $items
}

if ($VersionInfo) {
  $summary.version = $VersionInfo
}

$summaryObject = Convert-ToOrderedObject $summary
$summaryObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
return $summaryObject
