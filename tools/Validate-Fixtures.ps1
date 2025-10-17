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
$ManifestPath = ''
# Pair validation flags
$RequirePair = $false
$FailOnExpectedMismatch = $false
$EvidencePath = ''
for ($i=0; $i -lt $args.Length; $i++) {
  switch -Regex ($args[$i]) {
    '^-MinBytes$' { if ($i + 1 -lt $args.Length) { $i++; [int]$MinBytes = $args[$i] }; continue }
    '^-Quiet(Output)?$' { $QuietOutput = $true; continue }
    '^-Json$' { $EmitJson = $true; continue }
    '^-TestAllowFixtureUpdate$' { $TestAllowFixtureUpdate = $true; continue }
    '^-DisableToken$' { $DisableToken = $true; continue }
    '^-ManifestPath$' {
      if ($i + 1 -lt $args.Length) { $i++; $ManifestPath = [string]$args[$i] }
      continue
    }
    '^-RequirePair$' { $RequirePair = $true; continue }
    '^-FailOnExpectedMismatch$' { $FailOnExpectedMismatch = $true; continue }
    '^-EvidencePath$' { if ($i + 1 -lt $args.Length) { $i++; $EvidencePath = [string]$args[$i] }; continue }
  }
}

<#
SYNOPSIS
  Validates canonical fixture VIs (Phase 1 + Phase 2 hash manifest, refined schema & JSON support).
EXIT CODES
  0 ok | 2 missing | 3 untracked | 4 size issue (bytes mismatch or below fallback) | 5 multiple issues | 6 hash mismatch | 7 manifest error (schema / parse / hash compute) | 8 duplicate manifest entry
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
$missing = @(); $untracked = @(); $tooSmall = @(); $sizeMismatch = @(); $hashMismatch = @(); $manifestError = $false; $duplicateEntries = @(); $schemaIssues = @();

# Phase 2: Load manifest if present
$manifestPath = if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath } else { Join-Path $repoRoot 'fixtures.manifest.json' }
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

# Pair digest verification (when both roles exist)
$pairIssues = @()
$pairMismatch = $false
$expectedOutcomeMismatch = $false
$actualOutcome = 'unknown'
try {
  if ($manifest -and $manifest.items) {
    $base = $manifest.items | Where-Object { $_.role -eq 'base' } | Select-Object -First 1
    $head = $manifest.items | Where-Object { $_.role -eq 'head' } | Select-Object -First 1
    if ($base -and $head) {
      $bSha = ([string]$base.sha256).ToUpperInvariant()
      $hSha = ([string]$head.sha256).ToUpperInvariant()
      $bLen = [int64]$base.bytes
      $hLen = [int64]$head.bytes
      $canonical = 'sha256:{0}|bytes:{1}|sha256:{2}|bytes:{3}' -f $bSha,$bLen,$hSha,$hLen
      $sha = [System.Security.Cryptography.SHA256]::Create()
      $calc = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) | ForEach-Object { $_.ToString('X2') }) -join ''
      if (-not $manifest.pair -and $RequirePair) { Emit error 'Manifest missing pair block while roles are present' 7 }
      if ($manifest.pair) {
        if ($manifest.pair.canonical -and ([string]$manifest.pair.canonical) -ne $canonical) {
          $pairIssues += 'pair.canonical mismatch'
          $pairMismatch = $true
        }
        if ($manifest.pair.digest -and ([string]$manifest.pair.digest).ToUpperInvariant() -ne $calc) {
          $pairIssues += 'pair.digest mismatch (stale)'
          $pairMismatch = $true
        }
        # Outcome validation
        $expected = if ($manifest.pair.expectedOutcome) { ([string]$manifest.pair.expectedOutcome).ToLowerInvariant() } else { '' }
        if ($expected -and $expected -ne 'any') {
          function Get-OutcomeFromEvidence([string]$p) {
            if (-not (Test-Path -LiteralPath $p)) { return 'unknown' }
            try { $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { return 'unknown' }
            if ($o.PSObject.Properties.Name -contains 'diff') { return ((if ($o.diff) { 'diff' } else { 'identical' })) }
            if ($o.PSObject.Properties.Name -contains 'exitCode') {
              try {
                switch ([int]$o.exitCode) { 0 { 'identical' } 1 { 'diff' } default { 'unknown' } }
              } catch { 'unknown' }
            } else { 'unknown' }
          }
          # Resolve evidence path
          $actualOutcome = 'unknown'
          if ($EvidencePath) { $actualOutcome = Get-OutcomeFromEvidence $EvidencePath }
          if ($actualOutcome -eq 'unknown') {
            $defaultEvidence = @(
              (Join-Path $repoRoot 'results/fixture-drift/compare-exec.json')
            )
            foreach ($p in $defaultEvidence) { if ($actualOutcome -eq 'unknown' -and (Test-Path -LiteralPath $p)) { $actualOutcome = Get-OutcomeFromEvidence $p } }
            if ($actualOutcome -eq 'unknown') {
              $cands = Get-ChildItem -Path (Join-Path $repoRoot 'tests/results') -Recurse -File -Filter 'compare-exec.json','lvcompare-capture.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
              foreach ($f in $cands) { $actualOutcome = Get-OutcomeFromEvidence $f.FullName; if ($actualOutcome -ne 'unknown') { break } }
            }
          }
          if ($actualOutcome -eq 'unknown') {
            Emit info 'No evidence found to verify pair.expectedOutcome' 0
          } elseif ($actualOutcome -ne $expected) {
            $expectedOutcomeMismatch = $true
            $lvl = if ($FailOnExpectedMismatch) { 'error' } elseif ($manifest.pair.enforce -and ([string]$manifest.pair.enforce).ToLowerInvariant() -eq 'fail') { 'error' } elseif ($manifest.pair.enforce -and ([string]$manifest.pair.enforce).ToLowerInvariant() -eq 'warn') { 'warn' } else { 'info' }
            Emit $lvl ("pair.expectedOutcome={0} actual={1}" -f $expected,$actualOutcome) 0
          }
        }
      }
    }
  }
} catch { Emit error ("Pair validation failed: {0}" -f $_.Exception.Message) 7; $manifestError = $true }

foreach ($f in $fixtures) {
  if (-not (Test-Path -LiteralPath $f.Path)) { $missing += $f; continue }
  if ($tracked -notcontains $f.Name) { $untracked += $f; continue }
  $len = (Get-Item -LiteralPath $f.Path).Length
  # Enforce recorded byte count when present; fall back to global minimum threshold otherwise
  $expectedBytes = $null
  if ($manifestIndex.ContainsKey($f.Name) -and $null -ne $manifestIndex[$f.Name].bytes) {
    try { $expectedBytes = [int]$manifestIndex[$f.Name].bytes } catch { }
  }
  if ($null -ne $expectedBytes) {
    if ($len -ne $expectedBytes) { $sizeMismatch += @{ Name=$f.Name; Actual=$len; Expected=$expectedBytes } }
  } elseif ($len -lt $MinBytes) {
    $tooSmall += @{ Name=$f.Name; Length=$len; Min=$MinBytes }
  }
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

# Optional: auto-generate/refresh manifest when both fixtures changed (deterministic drift flag)
$autoManifestWritten = $false
$autoManifestReason  = $null
$autoManifestTarget  = $manifestPath
try {
  $defaultManifest = Join-Path $repoRoot 'fixtures.manifest.json'
  $isDefaultTarget = ([string]::IsNullOrWhiteSpace($ManifestPath) -or ((Resolve-Path -LiteralPath $defaultManifest -ErrorAction SilentlyContinue)?.Path -ieq (Resolve-Path -LiteralPath $manifestPath -ErrorAction SilentlyContinue)?.Path))
  if ($hashMismatch.Count -ge 2 -and -not $manifestError -and $isDefaultTarget) {
    # Create/refresh manifest to capture new bytes/hashes; keep non-zero exit to signal drift to CI.
    $updateScript = Join-Path $PSScriptRoot 'Update-FixtureManifest.ps1'
    if (Test-Path -LiteralPath $updateScript -PathType Leaf) {
      try {
        pwsh -NoLogo -NoProfile -File $updateScript -Force | Out-Null
        $autoManifestWritten = $true
        $autoManifestReason  = 'hashMismatch>=2'
        $autoManifestTarget  = $defaultManifest
      } catch {
        # Non-fatal: proceed without auto-write
      }
    }
  }
} catch { }

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

if (-not $missing -and -not $untracked -and -not $tooSmall -and -not $sizeMismatch -and -not $manifestError -and -not $hashMismatch -and -not $duplicateEntries -and -not $pairMismatch -and -not $expectedOutcomeMismatch) {
  $timestamp = (Get-Date).ToString('o')
  $fixtureNames = @($fixtures | ForEach-Object { $_.Name })
  if ($EmitJson) {
    $okObj = [ordered]@{
      schema = 'fixture-validation-v1'
      generatedAt = $timestamp
      ok = $true
      exitCode = 0
      summary = 'Fixture validation succeeded'
      issues = @()
      fixtures = $fixtureNames
      checked = $fixtureNames
      fixtureCount = $fixtureNames.Count
      manifestPresent = [bool]$manifest
      summaryCounts = [ordered]@{
        missing = 0
        untracked = 0
        tooSmall = 0
        sizeMismatch = 0
        hashMismatch = 0
        manifestError = 0
        duplicate = 0
        schema = 0
        pairMismatch = 0
        expectedOutcomeMismatch = 0
      }
      autoManifest = [ordered]@{
        written = $false
        reason  = [string]$autoManifestReason
        path    = [string]$manifestPath
      }
    }
    $okObj | ConvertTo-Json -Depth 6
    exit 0
  }
  Emit info 'Fixture validation succeeded' 0; exit 0 }

$exit = 0
if ($missing) { $exit = 2; foreach ($m in $missing) { Emit error ("Missing canonical fixture {0}" -f $m.Name) 2 } }
if ($untracked) { $exit = if ($exit -eq 0) { 3 } else { 5 }; foreach ($u in $untracked) { Emit error ("Fixture {0} is not git-tracked" -f $u.Name) 3 } }
if ($tooSmall) { $exit = if ($exit -eq 0) { 4 } else { 5 }; foreach ($s in $tooSmall) { Emit error ("Fixture {0} length {1} < MinBytes {2}" -f $s.Name,$s.Length,$s.Min) 4 } }
if ($sizeMismatch) { $exit = if ($exit -eq 0) { 4 } else { 5 }; foreach ($sm in $sizeMismatch) { Emit error ("Fixture {0} size mismatch (actual {1} expected {2})" -f $sm.Name,$sm.Actual,$sm.Expected) 4 } }
if ($manifestError) { $exit = if ($exit -eq 0) { 7 } else { 5 } }
if ($hashMismatch) { $exit = if ($exit -eq 0) { 6 } else { 5 }; foreach ($h in $hashMismatch) { Emit error ("Fixture {0} hash mismatch (actual {1} expected {2})" -f $h.Name,$h.Actual,$h.Expected) 6 } }
if ($duplicateEntries) { $exit = if ($exit -eq 0) { 8 } else { 5 } }

if ($EmitJson) {
  $timestamp = (Get-Date).ToString('o')
  $fixtureNames = @($fixtures | ForEach-Object { $_.Name })
  $issues = @()
  foreach ($m in $missing) { $issues += [ordered]@{ type='missing'; fixture=$m.Name } }
  foreach ($u in $untracked) { $issues += [ordered]@{ type='untracked'; fixture=$u.Name } }
  foreach ($s in $tooSmall) { $issues += [ordered]@{ type='tooSmall'; fixture=$s.Name; length=$s.Length; min=$s.Min } }
  foreach ($sm in $sizeMismatch) { $issues += [ordered]@{ type='sizeMismatch'; fixture=$sm.Name; actual=$sm.Actual; expected=$sm.Expected } }
  foreach ($h in $hashMismatch) { $issues += [ordered]@{ type='hashMismatch'; fixture=$h.Name; actual=$h.Actual; expected=$h.Expected } }
  if ($manifestError) { $issues += [ordered]@{ type='manifestError' } }
  foreach ($d in $duplicateEntries) { $issues += [ordered]@{ type='duplicate'; path=$d } }
  if ($pairMismatch) { $issues += [ordered]@{ type='pairMismatch' } }
  if ($expectedOutcomeMismatch) { $issues += [ordered]@{ type='expectedOutcomeMismatch'; expected=[string]$manifest.pair.expectedOutcome; actual=$actualOutcome } }
  foreach ($si in $schemaIssues) { $issues += [ordered]@{ type='schema'; detail=$si } }
  $obj = [ordered]@{
    schema = 'fixture-validation-v1'
    generatedAt = $timestamp
    ok = ($exit -eq 0)
    exitCode = $exit
    summary = if ($exit -eq 0) { 'Fixture validation succeeded' } else { 'Fixture validation failed' }
    issues = $issues
    manifestPresent = [bool]$manifest
    fixtureCount = $fixtures.Count
    fixtures = $fixtureNames
    checked = $fixtureNames
    summaryCounts = [ordered]@{
      missing = ($missing).Count
      untracked = ($untracked).Count
      tooSmall = ($tooSmall).Count
      sizeMismatch = ($sizeMismatch).Count
      hashMismatch = ($hashMismatch).Count
      manifestError = [int]($manifestError)
      duplicate = ($duplicateEntries).Count
      schema = ($schemaIssues).Count
      pairMismatch = [int]$pairMismatch
      expectedOutcomeMismatch = [int]$expectedOutcomeMismatch
    }
    autoManifest = [ordered]@{
      written = [bool]$autoManifestWritten
      reason  = [string]$autoManifestReason
      path    = [string]$autoManifestTarget
    }
  }
  $obj | ConvertTo-Json -Depth 8
}

exit $exit
