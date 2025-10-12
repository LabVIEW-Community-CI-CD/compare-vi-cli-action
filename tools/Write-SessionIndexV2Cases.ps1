#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$OutFileName = 'session-index.v2.cases.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$xmlPath = Join-Path $ResultsDir 'pester-results.xml'
if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
  Write-Host "No pester-results.xml found at $xmlPath; skipping cases emission." -ForegroundColor DarkGray
  return $null
}

[xml]$doc = Get-Content -LiteralPath $xmlPath
$caseNodes = $doc.SelectNodes('//test-case')
if ($caseNodes.Count -eq 0) {
  Write-Host 'No <test-case> nodes discovered in pester-results.xml' -ForegroundColor DarkGray
  return $null
}

$cases = @()
foreach ($node in $caseNodes) {
  $description = $node.description
  $name = $node.name
  $durationSeconds = 0
  if ($node.time -and [double]::TryParse($node.time, [ref]$null)) {
    $durationSeconds = [double]$node.time
  }
  $result = $node.result
  $success = $node.success
  $outcome = switch -Regex ($result) {
    'Success' { 'passed' }
    'Failure' { 'failed' }
    'Error' { 'error' }
    'Ignored' { 'skipped' }
    'Skipped' { 'skipped' }
    default {
      if ($success -eq 'True') { 'passed' } elseif ($success -eq 'False') { 'failed' } else { 'unknown' }
    }
  }
  $category = $null
  try {
    $suite = $node.ParentNode
    while ($suite -and $suite.name -eq $description) {
      $suite = $suite.ParentNode
    }
    if ($suite -and $suite.description) {
      $category = [string]$suite.description
    } elseif ($node.ParentNode -and $node.ParentNode.ParentNode -and $node.ParentNode.ParentNode.description) {
      $category = [string]$node.ParentNode.ParentNode.description
    }
  } catch { $category = $null }

  $cases += [ordered]@{
    id = $name
    description = $description
    category = $category
    outcome = $outcome
    durationMs = [Math]::Round($durationSeconds * 1000, 2)
    requirement = if ($name) { [string]$name } else { 'auto-generated-requirement' }
  }
}

$output = [pscustomobject]@{
  schema = 'session-index-cases/v1'
  schemaVersion = '1.0.0'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  cases = $cases
}

$outPath = if ([System.IO.Path]::IsPathRooted($OutFileName)) {
  $OutFileName
} else {
  Join-Path $ResultsDir $OutFileName
}

$output | ConvertTo-Json -Depth 5 | Out-File -FilePath $outPath -Encoding utf8
Write-Host "Session index test cases written to $outPath"
return $outPath
