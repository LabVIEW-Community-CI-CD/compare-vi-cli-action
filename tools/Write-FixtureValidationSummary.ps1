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

function Get-JsonArrayValue {
  param(
    [object]$Object,
    [string]$PropertyName
  )

  if ($null -eq $Object) { return @() }
  $prop = $Object.PSObject.Properties[$PropertyName]
  if ($null -eq $prop) { return @() }

  $value = $prop.Value
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) { return $value }
  if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
    $buffer = @()
    foreach ($item in $value) { $buffer += ,$item }
    return $buffer
  }
  return @($value)
}

function Get-JsonBooleanValue {
  param(
    [object]$Object,
    [string]$PropertyName,
    [bool]$Default = $false
  )

  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$PropertyName]
  if ($null -eq $prop) { return $Default }

  $value = $prop.Value
  if ($null -eq $value) { return $Default }
  if ($value -is [bool]) { return $value }

  try {
    return [System.Convert]::ToBoolean($value)
  }
  catch {
    return $Default
  }
}

if (-not $SummaryPath) { Write-Host 'No GITHUB_STEP_SUMMARY set; printing summary instead.' }

$verbose = ($env:SUMMARY_VERBOSE -eq 'true')
$lines = @('<!-- markdownlint-disable-next-line MD041 -->', '# Fixture Validation Summary')
if ($validation) {
  $lines += ''
  $lines += '## Current Snapshot'
  if ($validation.ok) {
    $lines += '- **Status:** OK'
  } else {
    $lines += '- **Status:** Issues Detected'
  }
  if ($validation.summaryCounts) {
    $sc = $validation.summaryCounts
    $lines += '- **Counts:**'
    $lines += ('  - missing: {0}' -f $sc.missing)
    $lines += ('  - untracked: {0}' -f $sc.untracked)
    $lines += ('  - tooSmall: {0}' -f $sc.tooSmall)
    if ($sc.PSObject.Properties.Name -contains 'sizeMismatch') {
      $lines += ('  - sizeMismatch: {0}' -f $sc.sizeMismatch)
    }
    $lines += ('  - hashMismatch: {0}' -f $sc.hashMismatch)
    $lines += ('  - manifestError: {0}' -f $sc.manifestError)
    $lines += ('  - duplicate: {0}' -f $sc.duplicate)
    $lines += ('  - schema: {0}' -f $sc.schema)
  }
}
if ($delta) {
  $lines += ''
  $lines += '## Delta'
  if ($delta.deltaCounts) {
    $pairs = @()
    foreach ($prop in $delta.deltaCounts.PSObject.Properties) { $pairs += ("{0}={1}" -f $prop.Name,$prop.Value) }
    if ($pairs.Count -gt 0) {
      $lines += ('- **Changed Categories:** ' + ($pairs -join ', '))
    } else {
      $lines += '- **Changed Categories:** _(none)_'
    }
  } else {
    $lines += '- **Changed Categories:** _(none)_'
  }
  $changeEntries = Get-JsonArrayValue -Object $delta -PropertyName 'changes'
  $newIssues = Get-JsonArrayValue -Object $delta -PropertyName 'newStructuralIssues'
  $derivedStructural = @()
  if ($changeEntries.Count -gt 0) {
    $structuralCategories = 'missing','untracked','hashMismatch','manifestError','duplicate','schema'
    $derivedStructural = @($changeEntries | Where-Object {
        $_.category -in $structuralCategories -and
        ([int]$_.baseline -eq 0) -and
        ([int]$_.current -gt 0)
      })
  }
  if ($newIssues.Count -eq 0 -and $derivedStructural.Count -gt 0) {
    $newIssues = $derivedStructural
  }
  $lines += ('- **New Structural Issues:** {0}' -f $newIssues.Count)
  $failOnNewIssues = Get-JsonBooleanValue -Object $delta -PropertyName 'failOnNewStructuralIssue'
  $willFailDefault = ($failOnNewIssues -and $newIssues.Count -gt 0)
  $willFail = Get-JsonBooleanValue -Object $delta -PropertyName 'willFail' -Default $willFailDefault
  $lines += ('- **Will Fail:** {0}' -f $willFail)
  if ($verbose -and $newIssues.Count -gt 0) {
    $lines += ''
    $lines += '### New Structural Issues Detail'
    foreach ($i in $newIssues) {
      $lines += ('- {0}: baseline={1} current={2} delta={3}' -f $i.category,$i.baseline,$i.current,$i.delta)
    }
  }
  if ($verbose -and $changeEntries.Count -gt 0) {
    $lines += ''
    $lines += '### All Changes'
    foreach ($c in $changeEntries) {
      $lines += ('- {0}: {1} -> {2} (Δ {3})' -f $c.category,$c.baseline,$c.current,$c.delta)
    }
  }
}

$body = ($lines -join [Environment]::NewLine)
if ($SummaryPath) { Add-Content -LiteralPath $SummaryPath -Value $body -Encoding utf8 } else { Write-Host $body }
