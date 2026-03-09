[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$SearchRoot,

  [Parameter(Mandatory)]
  [string]$FileName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
  throw "Artifact search root not found: $SearchRoot"
}

$resolvedRoot = (Resolve-Path -LiteralPath $SearchRoot).Path
$allFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File)
$matches = @($allFiles | Where-Object { $_.Name -eq $FileName } | Sort-Object FullName)

if ($matches.Count -eq 1) {
  $matches[0].FullName
  return
}

$availableFiles = @(
  $allFiles |
    Sort-Object FullName |
    ForEach-Object { [System.IO.Path]::GetRelativePath($resolvedRoot, $_.FullName) }
)

if ($matches.Count -eq 0) {
  $preview = @($availableFiles | Select-Object -First 20)
  $suffix = if ($availableFiles.Count -gt $preview.Count) { ', ...' } else { '' }
  $availableText = if ($preview.Count -gt 0) { ($preview -join ', ') + $suffix } else { '(none)' }
  throw "Artifact '$FileName' not found under '$resolvedRoot'. Available files: $availableText"
}

$matchText = @(
  $matches |
    ForEach-Object { [System.IO.Path]::GetRelativePath($resolvedRoot, $_.FullName) }
) -join ', '

throw "Artifact '$FileName' resolved ambiguously under '$resolvedRoot'. Matches: $matchText"
