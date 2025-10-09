param(
  [Parameter(Mandatory)]
  [string]$Title,
  [string]$Status = 'Draft',
  [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
  [string[]]$Requirements
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path '.').Path
$adrDir = Join-Path $repoRoot 'docs/adr'
$requirementsDir = Join-Path $repoRoot 'docs/requirements'
$readmePath = Join-Path $adrDir 'README.md'

if (-not (Test-Path -LiteralPath $adrDir -PathType Container)) {
  throw "ADR directory not found: $adrDir"
}

if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
  throw "ADR index not found: $readmePath"
}

$existing = @(Get-ChildItem -LiteralPath $adrDir -File -Filter '*.md' |
  Where-Object { $_.BaseName -match '^\d{4}-' })

$nextNumber = if ($existing.Count -gt 0) {
  ($existing | ForEach-Object { [int]($_.BaseName.Substring(0,4)) } | Measure-Object -Maximum).Maximum + 1
} else { 1 }

$adrId = $nextNumber.ToString('0000')

function ConvertTo-Slug([string]$text) {
  ($text.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
}

$slug = ConvertTo-Slug $Title
if (-not $slug) { $slug = "adr-$adrId" }

$fileName = "$adrId-$slug.md"
$filePath = Join-Path $adrDir $fileName
if (Test-Path -LiteralPath $filePath) {
  throw "ADR file already exists: $filePath"
}

function Resolve-RequirementLink([string]$value) {
  if (-not $value) { return $null }
  $candidate = $value
  if (-not [System.IO.Path]::HasExtension($candidate)) { $candidate = "$candidate.md" }
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $requirementsDir $candidate
  }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    Write-Warning "Requirement file not found: $value (looked for $candidate)"
    return $null
  }
  $relPath = [System.IO.Path]::GetRelativePath($adrDir, $candidate)
  $label = [System.IO.Path]::GetFileNameWithoutExtension($candidate)
  return @{ Label = $label; RelativePath = $relPath }
}

$requirementLinks = @()
if ($Requirements) {
  foreach ($req in $Requirements) {
    $link = Resolve-RequirementLink $req
    if ($link) { $requirementLinks += $link }
  }
}

$referencesSection = if ($requirementLinks.Count -gt 0) {
  ($requirementLinks | ForEach-Object {
    "- [`$($_.Label)`](../$($_.RelativePath))"
  }) -join "`n"
} else {
  "- _Add references here_"
}

$template = @"
# ADR $($adrId): $Title

## Status

$Status — $Date

## Context

_Describe the background and forces leading to this decision._

## Decision

_Record the decision that was made._

## Consequences

**Benefits**

- _List positive outcomes._

**Trade-offs**

- _List drawbacks or things to monitor._

## References

$referencesSection

"@

Set-Content -LiteralPath $filePath -Value $template -Encoding utf8

# Update ADR index
$indexLines = Get-Content -LiteralPath $readmePath
$tableDividerIndex = -1
for ($i = 0; $i -lt $indexLines.Count; $i++) {
  if ($indexLines[$i] -match '^\|-----') { $tableDividerIndex = $i; break }
}
$tableDividerIndex = [int]$tableDividerIndex
if ($tableDividerIndex -lt 0) { throw "ADR README table divider not found." }
$requirementsCell = if ($requirementLinks.Count -gt 0) {
  ($requirementLinks | ForEach-Object { "[`$($_.Label)`](../$($_.RelativePath))" }) -join ', '
} else {
  '_TBD_'
}
$newRow = "| [$adrId]($fileName) | $Title | $Status | $Date | $requirementsCell |"
if ($tableDividerIndex -eq $indexLines.Count - 1) {
  $indexLines = $indexLines + $newRow
} else {
  $before = $indexLines[0..$tableDividerIndex]
  $after = $indexLines[($tableDividerIndex + 1)..($indexLines.Count - 1)]
  $indexLines = $before + $newRow + $after
}
Set-Content -LiteralPath $readmePath -Value $indexLines -Encoding utf8

Write-Host ("Created ADR {0} at {1}" -f $adrId, $filePath) -ForegroundColor Green
if ($requirementLinks.Count -eq 0) {
  Write-Host "Reminder: add requirement references and run tools/Validate-AdrLinks.ps1 once you update requirement docs." -ForegroundColor Yellow
}
