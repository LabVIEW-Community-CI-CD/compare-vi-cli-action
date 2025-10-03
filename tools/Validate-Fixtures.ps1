${ErrorActionPreference} = 'Stop'
# Manual argument parsing (avoid param binding edge cases under certain hosts)
# Added refinement flags:
#   -Json : emit structured JSON summary to stdout (single object)
#   -TestAllowFixtureUpdate : INTERNAL test override (suppresses hash mismatch failure w/o commit token)
$MinBytes = 32
$QuietOutput = $false
$EmitJson = $false
$TestAllowFixtureUpdate = $false
$DisableToken = $false
for ($i=0; $i -lt $args.Length; $i++) {
  switch -Regex ($args[$i]) {
    '^-MinBytes$' { if ($i + 1 -lt $args.Length) { $i++; [int]$MinBytes = $args[$i] }; continue }
    '^-Quiet(Output)?$' { $QuietOutput = $true; continue }
    '^-Json$' { $EmitJson = $true; continue }
  '^-TestAllowFixtureUpdate$' { $TestAllowFixtureUpdate = $true; continue }
  '^-DisableToken$' { $DisableToken = $true; continue }
  }
}

<#
SYNOPSIS
  Validates canonical fixture VIs (Phase 1 + Phase 2 hash manifest, refined schema & JSON support).
EXIT CODES
  0 ok | 2 missing | 3 untracked | 4 too small | 5 multiple issues | 6 hash mismatch | 7 manifest error (schema / parse / hash compute) | 8 duplicate manifest entry
NOTES
  - When multiple categories occur exit code becomes 5 unless a manifest structural error (7) is sole issue.
  - Duplicate path entries trigger code 8 (or 5 if combined with others).
  - JSON output mode always prints a single JSON object to stdout (other console output suppressed except fatal parse errors before JSON assembly).
#>

## Quiet flag already normalized above

function Emit {
  param([string]$Level,[string]$Msg,[int]$Code)
  if ($EmitJson) { return } # suppress human lines in JSON mode
  if ($QuietOutput -and $Level -ne 'error') { return }
  $fmt = '[fixture] level={0} code={1} message="{2}"'
  Write-Host ($fmt -f $Level,$Code,$Msg)
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
$fixtures = @(
  @{ Name='VI1.vi'; Path=(Join-Path $repoRoot 'VI1.vi') }
  @{ Name='VI2.vi'; Path=(Join-Path $repoRoot 'VI2.vi') }
)
$tracked = (& git ls-files) -split "`n" | Where-Object { $_ }
$missing = @(); $untracked = @(); $tooSmall = @(); $hashMismatch = @(); $manifestError = $false; $duplicateEntries = @(); $schemaIssues = @();

# Phase 2: Load manifest if present
$manifestPath = Join-Path $repoRoot 'fixtures.manifest.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
  try {
    $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
    $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop
    if (-not $manifest.schema -or $manifest.schema -ne 'fixture-manifest-v1') { $schemaIssues += 'Invalid or missing schema (expected fixture-manifest-v1)' }
    if (-not $manifest.items -or $manifest.items.Count -eq 0) { $schemaIssues += 'Missing or empty items array' }
  } catch {
    Emit error ("Manifest read/parse failure: {0}" -f $_.Exception.Message) 7
    $manifestError = $true
  }
}

if ($manifest -and $schemaIssues) {
  $manifestError = $true
  foreach ($si in $schemaIssues) { Emit error ("Manifest schema issue: {0}" -f $si) 7 }
}

$manifestIndex = @{}
if ($manifest -and $manifest.items) {
  $seen = @{}
  foreach ($it in $manifest.items) {
    if (-not $it.path) { $schemaIssues += 'Item missing path'; continue }
    if ($seen.ContainsKey($it.path)) { $duplicateEntries += $it.path }
    else { $seen[$it.path] = $true }
    $manifestIndex[$it.path] = $it
  }
  if ($duplicateEntries) { foreach ($d in $duplicateEntries) { Emit error ("Manifest duplicate path entry: {0}" -f $d) 8 } }
}

foreach ($f in $fixtures) {
  if (-not (Test-Path -LiteralPath $f.Path)) { $missing += $f; continue }
  if ($tracked -notcontains $f.Name) { $untracked += $f; continue }
  $len = (Get-Item -LiteralPath $f.Path).Length
  # Enforce per-item minBytes (if manifest present) else global threshold
  $effectiveMin = $MinBytes
  if ($manifestIndex.ContainsKey($f.Name) -and $manifestIndex[$f.Name].minBytes) { $effectiveMin = [int]$manifestIndex[$f.Name].minBytes }
  if ($len -lt $effectiveMin) { $tooSmall += @{ Name=$f.Name; Length=$len; Min=$effectiveMin } }
  # Hash verification (Phase 2) when manifest present
  if ($manifest -and $manifestIndex.ContainsKey($f.Name)) {
    try {
      $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.Path).Hash.ToUpperInvariant()
      $expected = ($manifestIndex[$f.Name].sha256).ToUpperInvariant()
      if ($hash -ne $expected) { $hashMismatch += @{ Name=$f.Name; Actual=$hash; Expected=$expected } }
    } catch {
      Emit error ("Hash computation failed for {0}: {1}" -f $f.Name,$_.Exception.Message) 7
      $manifestError = $true
    }
  }
}

# Commit message token override
$allowOverride = $false
try {
  $headSha = (& git rev-parse -q HEAD 2>$null).Trim()
  if ($headSha) {
    $msg = (& git log -1 --pretty=%B 2>$null)
      # Token must appear on its own (word boundary) to activate override
    if (-not $DisableToken -and $msg -match '(?im)^.*\[fixture-update\].*$') { $allowOverride = $true }
  }
} catch { }

if (($allowOverride -or $TestAllowFixtureUpdate) -and $hashMismatch) {
  Emit info 'Hash mismatches ignored due to [fixture-update] token' 0
  $hashMismatch = @() # neutralize
}

if (-not $missing -and -not $untracked -and -not $tooSmall -and -not $manifestError -and -not $hashMismatch -and -not $duplicateEntries) {
  if ($EmitJson) {
    $names = @($fixtures | ForEach-Object { $_.Name })
    $okObj = [ordered]@{ 
      ok=$true; exitCode=0; summary='Fixture validation succeeded'; issues=@(); fixtures=$names; checked=$names; fixtureCount=$names.Count; manifestPresent=[bool]$manifest; 
      summaryCounts = [ordered]@{ missing=0; untracked=0; tooSmall=0; hashMismatch=0; manifestError=0; duplicate=0; schema=0 }
    }
    $okObj | ConvertTo-Json -Depth 6
    exit 0
  }
  Emit info 'Fixture validation succeeded' 0; exit 0 }

$exit = 0
if ($missing) { $exit = 2; foreach ($m in $missing) { Emit error ("Missing canonical fixture {0}" -f $m.Name) 2 } }
if ($untracked) { $exit = if ($exit -eq 0) { 3 } else { 5 }; foreach ($u in $untracked) { Emit error ("Fixture {0} is not git-tracked" -f $u.Name) 3 } }
if ($tooSmall) { $exit = if ($exit -eq 0) { 4 } else { 5 }; foreach ($s in $tooSmall) { Emit error ("Fixture {0} length {1} < MinBytes {2}" -f $s.Name,$s.Length,$s.Min) 4 } }
if ($manifestError) { $exit = if ($exit -eq 0) { 7 } else { 5 } }
if ($hashMismatch) { $exit = if ($exit -eq 0) { 6 } else { 5 }; foreach ($h in $hashMismatch) { Emit error ("Fixture {0} hash mismatch (actual {1} expected {2})" -f $h.Name,$h.Actual,$h.Expected) 6 } }
if ($duplicateEntries) { $exit = if ($exit -eq 0) { 8 } else { 5 } }

if ($EmitJson) {
  $issues = @()
  foreach ($m in $missing) { $issues += [ordered]@{ type='missing'; fixture=$m.Name } }
  foreach ($u in $untracked) { $issues += [ordered]@{ type='untracked'; fixture=$u.Name } }
  foreach ($s in $tooSmall) { $issues += [ordered]@{ type='tooSmall'; fixture=$s.Name; length=$s.Length; min=$s.Min } }
  foreach ($h in $hashMismatch) { $issues += [ordered]@{ type='hashMismatch'; fixture=$h.Name; actual=$h.Actual; expected=$h.Expected } }
  if ($manifestError) { $issues += [ordered]@{ type='manifestError' } }
  foreach ($d in $duplicateEntries) { $issues += [ordered]@{ type='duplicate'; path=$d } }
  foreach ($si in $schemaIssues) { $issues += [ordered]@{ type='schema'; detail=$si } }
  $obj = [ordered]@{
    ok = ($exit -eq 0)
    exitCode = $exit
    summary = if ($exit -eq 0) { 'Fixture validation succeeded' } else { 'Fixture validation failed' }
    issues = $issues
    manifestPresent = [bool]$manifest
    fixtureCount = $fixtures.Count
    checked = @($fixtures | ForEach-Object { $_.Name })
    summaryCounts = [ordered]@{
      missing = ($missing).Count
      untracked = ($untracked).Count
      tooSmall = ($tooSmall).Count
      hashMismatch = ($hashMismatch).Count
      manifestError = [int]($manifestError)
      duplicate = ($duplicateEntries).Count
      schema = ($schemaIssues).Count
    }
  }
  $obj | ConvertTo-Json -Depth 8
}

exit $exit
