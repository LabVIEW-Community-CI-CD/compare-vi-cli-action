param(
  [Parameter(Mandatory)][string]$Requirement,
  [Parameter(Mandatory)][string]$AdrId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path '.').Path
$reqDir = Join-Path $repoRoot 'docs/requirements'
$adrDir = Join-Path $repoRoot 'docs/adr'
$adrIndexPath = Join-Path $adrDir 'README.md'

function Resolve-RequirementPath {
  param([string]$Value)
  if ([IO.Path]::IsPathRooted($Value)) {
    return (Resolve-Path -LiteralPath $Value).Path
  }
  $candidate = Join-Path $reqDir $Value
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  if (-not [IO.Path]::HasExtension($Value)) {
    $candidate = Join-Path $reqDir ($Value + '.md')
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  throw "Requirement file not found: $Value"
}

function Resolve-AdrFile {
  param([string]$Id)
  $files = @(Get-ChildItem -LiteralPath $adrDir -File -Filter ($Id + '-*.md'))
  if ($files.Count -eq 0) { throw "ADR file not found for id $Id" }
  if ($files.Count -gt 1) { throw "Multiple ADR files found for id $Id" }
  return $files[0]
}

$reqPath = Resolve-RequirementPath -Value $Requirement
$reqName = [IO.Path]::GetFileNameWithoutExtension($reqPath)
$adrFile = Resolve-AdrFile -Id $AdrId
$adrFileName = $adrFile.Name

# Update requirement Traceability section.
$relativeAdrLink = [IO.Path]::GetRelativePath([IO.Path]::GetDirectoryName($reqPath), $adrFile.FullName).Replace('\','/')
$traceLine = "- Architectural Decision Record: [`ADR $AdrId`]($relativeAdrLink)"
$reqLines = @() + (Get-Content -LiteralPath $reqPath)
$hasTraceHeader = $false
$traceIndex = -1
for ($i = 0; $i -lt $reqLines.Count; $i++) {
  if ($reqLines[$i] -match '^\s*##\s*Traceability\s*$') { $hasTraceHeader = $true; $traceIndex = $i; break }
}
if (-not $hasTraceHeader) {
  if ($reqLines.Count -gt 0 -and $reqLines[-1].Trim().Length -ne 0) { $reqLines += '' }
  $reqLines += '## Traceability'
  $reqLines += ''
  $reqLines += $traceLine
} elseif ($reqLines -notcontains $traceLine) {
  $insertIndex = $traceIndex + 1
  while ($insertIndex -lt $reqLines.Count -and $reqLines[$insertIndex].Trim().Length -eq 0) { $insertIndex++ }
  if ($insertIndex -ge $reqLines.Count) {
    if ($reqLines.Count -gt 0 -and $reqLines[-1].Trim().Length -ne 0) { $reqLines += '' }
    $reqLines += $traceLine
  } elseif ($insertIndex -eq 0) {
    $reqLines = @($traceLine) + $reqLines
  } else {
    $reqLines = $reqLines[0..($insertIndex-1)] + @($traceLine) + $reqLines[$insertIndex..($reqLines.Count-1)]
  }
}
Set-Content -LiteralPath $reqPath -Value $reqLines -Encoding utf8

# Update ADR References section.
$reqRelativeFromAdr = [IO.Path]::GetRelativePath($adrDir, $reqPath).Replace('\','/')
$adrRequirementLine = "- [`$reqName`](../$reqRelativeFromAdr)"
$adrLines = @() + (Get-Content -LiteralPath $adrFile.FullName)
if ($adrLines -notcontains $adrRequirementLine) {
$referencesIndex = -1
for ($i = 0; $i -lt $adrLines.Count; $i++) {
  if ($adrLines[$i].Trim() -eq '## References') { $referencesIndex = $i; break }
}
if ($referencesIndex -lt 0) { throw "ADR missing References section: $($adrFile.FullName)" }
  $insertIndex = $referencesIndex + 1
  while ($insertIndex -lt $adrLines.Count -and $adrLines[$insertIndex].Trim() -eq '') { $insertIndex++ }
  if ($insertIndex -ge $adrLines.Count) {
    $adrLines += ''
    $adrLines += $adrRequirementLine
  } else {
    $adrLines = $adrLines[0..($insertIndex-1)] + @($adrRequirementLine) + $adrLines[$insertIndex..($adrLines.Count-1)]
  }
  Set-Content -LiteralPath $adrFile.FullName -Value $adrLines -Encoding utf8
}

# Update ADR index table.
if (-not (Test-Path -LiteralPath $adrIndexPath -PathType Leaf)) {
  throw "ADR index not found: $adrIndexPath"
}
$indexLines = @() + (Get-Content -LiteralPath $adrIndexPath)
$rowIndex = -1
for ($i = 0; $i -lt $indexLines.Count; $i++) {
  if ($indexLines[$i] -match "^\|\s*\[$AdrId\]") { $rowIndex = $i; break }
}
if ($rowIndex -ge 0) {
  $row = $indexLines[$rowIndex]
  $reqLink = "[`$reqName`](../$reqRelativeFromAdr)"
  if ($row -notmatch [regex]::Escape($reqLink)) {
    $parts = $row.Split('|')
    $reqCellIndex = $parts.Length - 2
    $cell = $parts[$reqCellIndex].Trim()
    if ($cell -eq '_TBD_' -or [string]::IsNullOrWhiteSpace($cell)) {
      $cell = $reqLink
    } else {
      $cell = "$cell, $reqLink"
    }
    $parts[$reqCellIndex] = " $cell "
    $indexLines[$rowIndex] = ($parts -join '|')
    Set-Content -LiteralPath $adrIndexPath -Value $indexLines -Encoding utf8
  }
}

Write-Host ("Linked requirement '{0}' to ADR {1}" -f $reqName, $AdrId) -ForegroundColor Green
