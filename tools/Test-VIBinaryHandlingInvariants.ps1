#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RepoRoot = (Join-Path $PSScriptRoot '..'),
  [string]$OutputJsonPath = '',
  [string]$StepSummaryPath = '',
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-PortablePath {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return ($Value -replace '\\', '/')
}

function New-TextualReadPattern {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Pattern,
    [Parameter(Mandatory)][string]$Description
  )

  return [pscustomobject]@{
    id = $Id
    regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    description = $Description
  }
}

$repoRootResolved = Resolve-AbsolutePath -Path $RepoRoot
$attrPath = Join-Path $repoRootResolved '.gitattributes'
$selfPath = Resolve-AbsolutePath -Path $PSCommandPath
$scannedRoots = @(
  Join-Path $repoRootResolved 'scripts'
  Join-Path $repoRootResolved 'tools'
)

$textualReadPatterns = @(
  (New-TextualReadPattern -Id 'get-content-vi' -Pattern 'Get-Content\s+[^\r\n]*\.vi(\b|[''"`])' -Description 'Direct Get-Content against a .vi path'),
  (New-TextualReadPattern -Id 'readalltext-vi' -Pattern 'ReadAllText\s*\([^\r\n]*\.vi(\b|[''"`])' -Description 'Direct ReadAllText against a .vi path'),
  (New-TextualReadPattern -Id 'open-text-vi' -Pattern 'OpenText\s*\([^\r\n]*\.vi(\b|[''"`])' -Description 'Direct OpenText against a .vi path'),
  (New-TextualReadPattern -Id 'streamreader-vi' -Pattern 'StreamReader(?:\]::new|\s*\()[^\r\n]*\.vi(\b|[''"`])' -Description 'Direct StreamReader against a .vi path')
)

$checks = @()
$violations = @()

$attrOk = $false
$attrMessage = ''
if (Test-Path -LiteralPath $attrPath -PathType Leaf) {
  $attrContent = Get-Content -LiteralPath $attrPath -Raw
  $attrOk = [regex]::IsMatch($attrContent, '(?m)^\*\.vi\s+binary\s*$')
  if (-not $attrOk) {
    $attrMessage = '*.vi binary declaration is missing from .gitattributes.'
  }
} else {
  $attrMessage = '.gitattributes is missing.'
}

$checks += [pscustomobject]@{
  id = 'gitattributes-vi-binary'
  status = if ($attrOk) { 'passed' } else { 'failed' }
  message = if ($attrOk) { '*.vi is declared as binary.' } else { $attrMessage }
  path = ''
}

$filesScanned = 0
foreach ($root in $scannedRoots) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    continue
  }

  $psFiles = Get-ChildItem -LiteralPath $root -Recurse -Include *.ps1,*.psm1 -File |
    Where-Object {
      $_.FullName -notmatch '[/\\]tests[/\\]' -and
      (Resolve-AbsolutePath -Path $_.FullName) -ne $selfPath
    }
  foreach ($file in $psFiles) {
    $filesScanned += 1
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $textualReadPatterns) {
      $matches = $pattern.regex.Matches($content)
      foreach ($match in $matches) {
        $violations += [pscustomobject]@{
          file = $file.FullName
          patternId = $pattern.id
          description = $pattern.description
          excerpt = [string]$match.Value
        }
      }
    }
  }
}

$checks[0].path = ConvertTo-PortablePath -Value $attrPath
foreach ($violation in $violations) {
  $violation.file = ConvertTo-PortablePath -Value $violation.file
}

$portableRepoRoot = ConvertTo-PortablePath -Value $repoRootResolved
$portableScannedRoots = @($scannedRoots | ForEach-Object { ConvertTo-PortablePath -Value $_ })

$checks += [pscustomobject]@{
  id = 'no-textual-vi-reads'
  status = if ($violations.Count -eq 0) { 'passed' } else { 'failed' }
  message = if ($violations.Count -eq 0) {
    'No direct textual .vi reads were detected in scripts/ or tools/.'
  } else {
    ('Detected {0} direct textual .vi read pattern(s).' -f $violations.Count)
  }
  scannedRoots = $portableScannedRoots
  filesScanned = $filesScanned
}

$status = if (@($checks | Where-Object { $_.status -ne 'passed' }).Count -eq 0) { 'passed' } else { 'failed' }
$report = [pscustomobject]@{
  schema = 'comparevi/vi-binary-handling-invariants@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  status = $status
  repoRoot = $portableRepoRoot
  checks = @($checks)
  violationCount = @($violations).Count
  violations = @($violations)
}

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  $outputPathResolved = Resolve-AbsolutePath -Path $OutputJsonPath
  $outputParent = Split-Path -Parent $outputPathResolved
  if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
  }
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputPathResolved -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $summaryPathResolved = Resolve-AbsolutePath -Path $StepSummaryPath
  $summaryLines = @(
    '### VI Binary Handling Invariants',
    '',
    ('- status: `{0}`' -f $status),
    ('- repo_root: `{0}`' -f (ConvertTo-PortablePath -Value $repoRootResolved)),
    ('- files_scanned: `{0}`' -f $filesScanned),
    ('- violation_count: `{0}`' -f $violations.Count)
  )
  if ($violations.Count -gt 0) {
    $summaryLines += ''
    $summaryLines += '#### Violations'
    foreach ($violation in $violations) {
      $summaryLines += ('- `{0}` `{1}`' -f $violation.file, $violation.patternId)
    }
  }
  $summaryLines -join "`n" | Out-File -LiteralPath $summaryPathResolved -Encoding utf8 -Append
}

if ($PassThru) {
  $report
}

if ($status -ne 'passed') {
  throw ('VI binary handling invariants failed. See report schema comparevi/vi-binary-handling-invariants@v1.')
}
