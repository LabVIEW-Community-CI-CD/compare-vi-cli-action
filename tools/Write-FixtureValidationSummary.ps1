param(
  [string]$ValidationJson = 'fixture-validation.json',
  [string]$DeltaJson = 'fixture-validation-delta.json',
  [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY
)
$ErrorActionPreference = 'Stop'

function Get-JsonContent($p) {
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

$validation = Get-JsonContent $ValidationJson
$delta = Get-JsonContent $DeltaJson

if (-not $SummaryPath) { Write-Host 'No GITHUB_STEP_SUMMARY set; printing summary instead.' }

$verbose = ($env:SUMMARY_VERBOSE -eq 'true')
$lines = @('# Fixture Validation Summary')
if ($validation) {
  $lines += ''
  $lines += '## Current Snapshot'
  if ($validation.ok) { $lines += 'Status: OK' } else { $lines += 'Status: Issues Detected' }
  if ($validation.summaryCounts) {
    $sc = $validation.summaryCounts
    $lines += ('Counts: missing={0} untracked={1} tooSmall={2} hashMismatch={3} manifestError={4} duplicate={5} schema={6}' -f `
      $sc.missing,$sc.untracked,$sc.tooSmall,$sc.hashMismatch,$sc.manifestError,$sc.duplicate,$sc.schema)
  }
}
if ($delta) {
  $lines += ''
  $lines += '## Delta'
  if ($delta.deltaCounts) {
    $pairs = @()
    foreach ($prop in $delta.deltaCounts.PSObject.Properties) { $pairs += ("{0}={1}" -f $prop.Name,$prop.Value) }
    $lines += ('Changed Categories: ' + ($pairs -join ', '))
  } else {
    $lines += 'Changed Categories: (none)'
  }
  $lines += ('New Structural Issues: ' + $delta.newStructuralIssues.Count)
  $lines += ('Will Fail: ' + $delta.willFail)
  if ($verbose -and $delta.newStructuralIssues.Count -gt 0) {
    $lines += ''
    $lines += '### New Structural Issues Detail'
    foreach ($i in $delta.newStructuralIssues) {
      $lines += ('- {0}: baseline={1} current={2} delta={3}' -f $i.category,$i.baseline,$i.current,$i.delta)
    }
  }
  if ($verbose -and $delta.changes.Count -gt 0) {
    $lines += ''
    $lines += '### All Changes'
    foreach ($c in $delta.changes) {
      $lines += ('- {0}: {1} -> {2} (Δ {3})' -f $c.category,$c.baseline,$c.current,$c.delta)
    }
  }
}

$body = ($lines -join [Environment]::NewLine)
if ($SummaryPath) { Add-Content -LiteralPath $SummaryPath -Value $body -Encoding utf8 } else { Write-Host $body }
