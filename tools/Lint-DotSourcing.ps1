[CmdletBinding()]
param(
  [switch] $WarnOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsRelativeDotSource {
  param(
    [string] $Line
  )

  if (-not $Line) { return $false }

  $trimmed = $Line.TrimStart()
  if (-not $trimmed.StartsWith('.', [System.StringComparison]::Ordinal)) { return $false }

  $afterDot = $trimmed.Substring(1).TrimStart()
  if ([string]::IsNullOrWhiteSpace($afterDot)) { return $false }

  $firstChar = $afterDot[0]
  if ($firstChar -eq '"') {
    if ($afterDot.Length -eq 1) { return $false }
    $afterDot = $afterDot.Substring(1)
  } elseif ($firstChar -eq "'") {
    if ($afterDot.Length -eq 1) { return $false }
    $afterDot = $afterDot.Substring(1)
  }

  if ($afterDot.StartsWith('./', [System.StringComparison]::Ordinal) -or
      $afterDot.StartsWith('.\\', [System.StringComparison]::Ordinal) -or
      $afterDot.StartsWith('../', [System.StringComparison]::Ordinal) -or
      $afterDot.StartsWith('..\\', [System.StringComparison]::Ordinal)) {
    return $true
  }

  return $false
}

$repoRoot = (Get-Location).Path
$searchPatterns = '*.ps1', '*.psm1', '*.psd1'
$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Include $searchPatterns |
  Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }

$violations = New-Object System.Collections.Generic.List[object]

foreach ($file in $files) {
  $lines = @(Get-Content -LiteralPath $file.FullName)
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $lineText = $lines[$index]
    $trimmed = $lineText.Trim()
    if ($trimmed.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }

    if (Test-IsRelativeDotSource -Line $lineText) {
      $violations.Add([pscustomobject]@{
        File = $file.FullName
        Line = $index + 1
        Text = $lineText.Trim()
      })
    }
  }
}

if ($violations.Count -eq 0) {
  Write-Host 'Dot-sourcing lint: OK'
  exit 0
}

$annotationType = if ($WarnOnly) { 'warning' } else { 'error' }
$message = 'Avoid dot-sourcing relative paths; use Import-Module or an absolute script path instead.'

foreach ($violation in $violations) {
  Write-Host ("::{0} file={1},line={2}::{3}" -f $annotationType, $violation.File, $violation.Line, $message)
  Write-Host ("  >> {0}" -f $violation.Text)
}

if ($WarnOnly) {
  exit 0
}

exit 2
