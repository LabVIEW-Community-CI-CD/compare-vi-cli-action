<#
  TestHelpers.Schema.ps1
  Lightweight JSON schema/style assertion helpers for test reuse.

  Provides:
    Assert-JsonShape -Path <file> -Spec <name>

  Specs implemented initially:
    FinalStatus  -> final status JSON emitted by Run-AutonomousIntegrationLoop
    RunSummary   -> run summary JSON produced by compare loop

  Design goals:
    - Zero external dependencies
    - Fail fast with aggregated errors
    - Simple type predicates via scriptblocks
    - Optional properties supported
    - Tolerant of additional properties (forward compatible)
#>

Set-StrictMode -Version Latest

# Initialize spec dictionary safely under strict mode
if (-not (Get-Variable -Name JsonShapeSpecs -Scope Script -ErrorAction SilentlyContinue)) {
  $script:JsonShapeSpecs = @{}
}

$script:JsonShapeSpecs['FinalStatus'] = [pscustomobject]@{
  Required = @('schema','timestamp','iterations','diffs','errors','succeeded')
  Optional = @('averageSeconds','totalSeconds','percentiles','histogram','diffSummaryEmitted','basePath','headPath','harness')
  Types    = @{
    schema            = { param($v) $v -is [string] -and $v -eq 'loop-final-status-v1' }
  timestamp         = { param($v) ($v -is [string] -or $v -is [datetime]) }
  iterations        = { param($v) (($v -is [int]) -or ($v -is [long]) -or ($v -is [double])) -and $v -ge 0 }
  diffs             = { param($v) (($v -is [int]) -or ($v -is [long]) -or ($v -is [double])) -and $v -ge 0 }
  errors            = { param($v) (($v -is [int]) -or ($v -is [long]) -or ($v -is [double])) -and $v -ge 0 }
    succeeded         = { param($v) $v -is [bool] }
    averageSeconds    = { param($v) -not $v -or $v -is [double] -or $v -is [int] }
    totalSeconds      = { param($v) -not $v -or $v -is [double] -or $v -is [int] }
    percentiles       = { param($v) -not $v -or ($v -is [hashtable] -or $v -is [pscustomobject]) }
    histogram         = { param($v) -not $v -or ($v -is [hashtable] -or $v -is [pscustomobject]) }
    diffSummaryEmitted= { param($v) -not $v -or $v -is [bool] }
    basePath          = { param($v) -not $v -or $v -is [string] }
    headPath          = { param($v) -not $v -or $v -is [string] }
    harness           = { param($v) -not $v -or ($v -is [hashtable] -or $v -is [pscustomobject]) }
  }
}

# Actual emitted run summary currently uses:
#   schema (e.g. 'compare-loop-run-summary-v1'), iterations, percentiles, requestedPercentiles,
#   optional histogram, diffs, errors, succeeded (some may be omitted in fast runs)
$script:JsonShapeSpecs['RunSummary'] = [pscustomobject]@{
  Required = @('schema','iterations','percentiles','requestedPercentiles')
  Optional = @('histogram','diffs','errors','succeeded','averageSeconds','totalSeconds')
  Types    = @{
    schema              = { param($v) $v -is [string] -and $v -like 'compare-loop-run-summary-*' }
    iterations          = { param($v) ((($v -is [int]) -or ($v -is [long]) -or ($v -is [double])) -and $v -ge 0) -or ($v -is [string] -and $v -match '^[0-9]+$') }
    percentiles         = { param($v) $v -is [pscustomobject] -or $v -is [hashtable] }
    requestedPercentiles= { param($v) $v -is [object[]] }
  histogram           = { param($v) -not $v -or $v -is [pscustomobject] -or $v -is [hashtable] -or $v -is [object[]] -or ($v -is [string]) }
    diffs               = { param($v) -not $v -or $v -is [int] -or $v -is [long] -or $v -is [double] -or ($v -is [string] -and $v -match '^[0-9]+$') }
    errors              = { param($v) -not $v -or $v -is [int] -or $v -is [long] -or $v -is [double] -or ($v -is [string] -and $v -match '^[0-9]+$') }
    succeeded           = { param($v) -not $v -or $v -is [bool] }
    averageSeconds      = { param($v) -not $v -or $v -is [double] -or $v -is [int] }
    totalSeconds        = { param($v) -not $v -or $v -is [double] -or $v -is [int] }
  }
}

# Snapshot schema (metrics-snapshot-v2 lines)
$script:JsonShapeSpecs['SnapshotV2'] = [pscustomobject]@{
  Required = @('schema','iteration','percentiles')
  Optional = @('requestedPercentiles','histogram','elapsedSeconds','diffs','errors')
  Types = @{
    schema              = { param($v) $v -eq 'metrics-snapshot-v2' }
  iteration           = { param($v) ($v -is [int] -or $v -is [long] -or ($v -is [string] -and $v -match '^[0-9]+$')) -and [int]$v -gt 0 }
    percentiles         = { param($v) $v -is [pscustomobject] -or $v -is [hashtable] }
    requestedPercentiles= { param($v) -not $v -or $v -is [object[]] }
  histogram           = { param($v) -not $v -or $v -is [pscustomobject] -or $v -is [hashtable] -or $v -is [object[]] -or ($v -is [string]) }
    elapsedSeconds      = { param($v) -not $v -or $v -is [double] -or $v -is [int] }
    diffs               = { param($v) -not $v -or $v -is [int] }
    errors              = { param($v) -not $v -or $v -is [int] }
  }
}

# Loop event NDJSON (loop-script-events-v1) meta/result/finalStatusEmitted lines
$script:JsonShapeSpecs['LoopEvent'] = [pscustomobject]@{
  Required = @('schema','timestamp','type')
  Optional = @('action','level','iterations','diffs','errors','succeeded','from','to','path')
  Types = @{
    schema     = { param($v) $v -eq 'loop-script-events-v1' }
  # Accept either already-parsed DateTime (some producers may emit [datetime]) or ISO-ish string
  timestamp  = { param($v) ($v -is [datetime]) -or ($v -is [string] -and $v.Length -ge 10) }
    type       = { param($v) $v -is [string] }
    action     = { param($v) -not $v -or $v -is [string] }
    level      = { param($v) -not $v -or $v -is [string] }
  iterations = { param($v) -not $v -or $v -is [int] -or $v -is [long] -or $v -is [double] }
  diffs      = { param($v) -not $v -or $v -is [int] -or $v -is [long] -or $v -is [double] }
  errors     = { param($v) -not $v -or $v -is [int] -or $v -is [long] -or $v -is [double] }
    succeeded  = { param($v) -not $v -or $v -is [bool] }
    from       = { param($v) -not $v -or $v -is [string] }
    to         = { param($v) -not $v -or $v -is [string] }
    path       = { param($v) -not $v -or $v -is [string] }
  }
}

$script:JsonShapeSpecs['IntegrationRunbook'] = [pscustomobject]@{
  Required = @('schema','generated','phases','overallStatus')
  Optional = @()
  Types = @{
    schema        = { param($v) $v -is [string] -and $v -eq 'integration-runbook-v1' }
    generated     = { param($v) ($v -is [string]) -or ($v -is [datetime]) }
    overallStatus = { param($v) $v -is [string] -and $v -match '^(Passed|Failed)$' }
    phases        = { param($v) $v -is [object[]] }
  }
}

function Assert-JsonShape {
  [CmdletBinding()] param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Spec,
    [switch]$Strict,
    [string]$FailureJsonPath,
    [switch]$NoThrow
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Assert-JsonShape: file not found: $Path"
  }
  if (-not $script:JsonShapeSpecs.ContainsKey($Spec)) {
    throw "Assert-JsonShape: unknown spec '$Spec'"
  }
  $jsonText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  try { $obj = $jsonText | ConvertFrom-Json -ErrorAction Stop } catch {
    $errMsg = "invalid JSON: $($_.Exception.Message)"
    if ($FailureJsonPath) { Write-FailureJson -FailureJsonPath $FailureJsonPath -Spec $Spec -SourcePath $Path -Errors @($errMsg) }
    if (-not $NoThrow) { throw "Assert-JsonShape: $errMsg" } else { return $false }
  }
  $specDef = $script:JsonShapeSpecs[$Spec]
  $errors = New-Object System.Collections.Generic.List[string]

  foreach ($key in $specDef.Required) {
    if (-not ($obj.PSObject.Properties.Name -contains $key)) {
      $errors.Add("missing required property '$key'")
    }
  }

  foreach ($prop in $obj.PSObject.Properties) {
    $name = $prop.Name
    $val  = $prop.Value
    $isKnown = $specDef.Required -contains $name -or $specDef.Optional -contains $name -or $specDef.Types.ContainsKey($name)
    if (-not $isKnown -and $Strict) {
      $errors.Add("unexpected property '$name' (Strict mode)")
      continue
    }
    if ($isKnown -and $specDef.Types.ContainsKey($name)) {
      $predicate = $specDef.Types[$name]
      $ok = & $predicate $val
      if (-not $ok) { $errors.Add("property '$name' failed type predicate (value='$val')") }
    }
  }

  if ($errors.Count -gt 0) {
    if ($FailureJsonPath) { Write-FailureJson -FailureJsonPath $FailureJsonPath -Spec $Spec -SourcePath $Path -Errors $errors }
    if (-not $NoThrow) { throw ("Assert-JsonShape FAILED for spec '{0}' on file '{1}':`n - {2}" -f $Spec,$Path,($errors -join "`n - ")) }
    return $false
  }
  return $true
}

function Assert-NdjsonShapes {
  [CmdletBinding()] param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Spec,
    [switch]$Strict,
    [string]$FailureJsonPath,
    [switch]$NoThrow
  )
  if (-not (Test-Path -LiteralPath $Path)) { throw "Assert-NdjsonShapes: file not found: $Path" }
  if (-not $script:JsonShapeSpecs.ContainsKey($Spec)) { throw "Assert-NdjsonShapes: unknown spec '$Spec'" }
  $specDef = $script:JsonShapeSpecs[$Spec]
  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
  $idx = 0
  $lineErrors = New-Object System.Collections.Generic.List[object]
  foreach ($l in $lines) {
    $idx++
    if (-not $l.Trim()) { continue }
    try { $tmp = $l | ConvertFrom-Json -ErrorAction Stop } catch { $lineErrors.Add([pscustomobject]@{ line=$idx; errors=@("invalid JSON: $($_.Exception.Message)") }); continue }
    # Validate inline similar to Assert-JsonShape (avoid temp file)
    $innerErrors = New-Object System.Collections.Generic.List[string]
    foreach ($req in $specDef.Required) { if (-not ($tmp.PSObject.Properties.Name -contains $req)) { $innerErrors.Add("missing required property '$req'") } }
    foreach ($prop in $tmp.PSObject.Properties) {
      $n=$prop.Name; $v=$prop.Value
      $isKnown = $specDef.Required -contains $n -or $specDef.Optional -contains $n -or $specDef.Types.ContainsKey($n)
      if (-not $isKnown -and $Strict) { $innerErrors.Add("unexpected property '$n' (Strict mode)"); continue }
      if ($isKnown -and $specDef.Types.ContainsKey($n)) { if (-not (& $specDef.Types[$n] $v)) { $innerErrors.Add("property '$n' failed type predicate (value='$v')") } }
    }
    if ($innerErrors.Count -gt 0) { $lineErrors.Add([pscustomobject]@{ line=$idx; errors=@($innerErrors) }) }
  }
  if ($lineErrors.Count -gt 0) {
    if ($FailureJsonPath) { Write-FailureJson -FailureJsonPath $FailureJsonPath -Spec $Spec -SourcePath $Path -LineErrors $lineErrors }
    if (-not $NoThrow) { throw "Assert-NdjsonShapes FAILED for spec '$Spec' on file '$Path' with $($lineErrors.Count) line error(s)." }
    return $false
  }
  return $true
}

# Note: No Export-ModuleMember call here; this helper is dot-sourced (not a module).

function Export-JsonShapeSchemas {
  <#
    .SYNOPSIS
      Export lightweight JSON Schema (Draft 2020-12 flavored) documents for all registered specs.
    .PARAMETER OutputDirectory
      Directory to write schema files (one per spec: <spec>.schema.json)
    .PARAMETER Overwrite
      Overwrite existing files if present.
    .NOTES
      This generates a conservative schema: required properties enumerated, known optional properties allowed,
      and additionalProperties=false to match Strict mode assumptions.
  #>
  [CmdletBinding()] param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$Overwrite,
    [switch]$InferTypes
  )
  if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
  foreach ($specName in $script:JsonShapeSpecs.Keys) {
    $def = $script:JsonShapeSpecs[$specName]
    $properties = @{}
    foreach ($r in $def.Required) { $properties[$r] = @{ description = "Required field from spec '$specName'" } }
    foreach ($o in $def.Optional) { if (-not $properties.ContainsKey($o)) { $properties[$o] = @{ description = "Optional field from spec '$specName'" } } }

    if ($InferTypes) {
      foreach ($pName in $def.Types.Keys) {
        if (-not $properties.ContainsKey($pName)) { continue }
        $text = $def.Types[$pName].ToString()
        $types = New-Object System.Collections.Generic.HashSet[string]
        if ($text -match '\[bool\]') { $types.Add('boolean') | Out-Null }
        if ($text -match '\[string\]') { $types.Add('string') | Out-Null }
        if ($text -match '\[int\]' -or $text -match '\[long\]') { $types.Add('integer') | Out-Null }
        if ($text -match '\[double\]') { $types.Add('number') | Out-Null }
        if ($text -match '\[pscustomobject\]' -or $text -match '\[hashtable\]') { $types.Add('object') | Out-Null }
        if ($text -match 'object\[\]') { $types.Add('array') | Out-Null }
        if ($types.Count -eq 0) { continue }
        if ($types.Count -eq 1) { $properties[$pName] = ($properties[$pName] + @{ type = ($types | Select-Object -First 1) }) }
        else { $properties[$pName] = ($properties[$pName] + @{ type = @($types) }) }
      }
    }
    $schema = [ordered]@{
      '$schema' = 'https://json-schema.org/draft/2020-12/schema'
      title = $specName
      description = "Auto-generated minimal JSON Schema for spec '$specName'. Types are not enforced (predicate-based in tests)."
      type = 'object'
      required = @($def.Required)
      properties = $properties
      additionalProperties = $false
    }
    $outPath = Join-Path $OutputDirectory ("{0}.schema.json" -f $specName)
    if ((Test-Path -LiteralPath $outPath) -and -not $Overwrite) { throw "Schema file already exists: $outPath (use -Overwrite)" }
    ($schema | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $outPath -Encoding UTF8
  }
  return Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.schema.json'
}

function Compare-JsonShape {
  <#
    .SYNOPSIS
      Compares two JSON documents against a spec and reports structural & value differences.
    .OUTPUTS
      PSCustomObject with properties: Spec, BaselinePath, CandidatePath, MissingInCandidate,
      MissingInBaseline, UnexpectedInCandidate, PredicateFailuresCandidate, ValueDifferences.
  #>
  [CmdletBinding()] param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$CandidatePath,
    [Parameter(Mandatory)][string]$Spec,
    [switch]$Strict
  )
  # assumes helper already dot-sourced
  foreach ($p in @($BaselinePath,$CandidatePath)) { if (-not (Test-Path -LiteralPath $p)) { throw "Compare-JsonShape: file not found: $p" } }
  $specDef = $script:JsonShapeSpecs[$Spec]
  $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
  $candidate = Get-Content -LiteralPath $CandidatePath -Raw | ConvertFrom-Json
  $result = [pscustomobject]@{
    Spec = $Spec
    BaselinePath = $BaselinePath
    CandidatePath = $CandidatePath
    MissingInCandidate = @()
    MissingInBaseline = @()
    UnexpectedInCandidate = @()
    PredicateFailuresCandidate = @()
    ValueDifferences = @()
  }
  $bProps = $baseline.PSObject.Properties.Name
  $cProps = $candidate.PSObject.Properties.Name
  foreach ($req in $specDef.Required) {
    if (-not ($cProps -contains $req)) { $result.MissingInCandidate += $req }
    if (-not ($bProps -contains $req)) { $result.MissingInBaseline += $req }
  }
  if ($Strict) {
    foreach ($p in $cProps) {
      $isKnown = $specDef.Required -contains $p -or $specDef.Optional -contains $p -or $specDef.Types.ContainsKey($p)
      if (-not $isKnown) { $result.UnexpectedInCandidate += $p }
    }
  }
  foreach ($p in $specDef.Types.Keys) {
    if ($cProps -contains $p) {
      $pred = $specDef.Types[$p]
      if (-not (& $pred $candidate.$p)) { $result.PredicateFailuresCandidate += $p }
    }
  }
  # simple scalar value differences for overlapping props (string/int/bool/double)
  foreach ($p in ($bProps | Where-Object { $cProps -contains $_ })) {
    $bv = $baseline.$p; $cv = $candidate.$p
    $scalar = ($bv -is [string] -or $bv -is [int] -or $bv -is [double] -or $bv -is [long] -or $bv -is [bool]) -and ($cv -is [string] -or $cv -is [int] -or $cv -is [double] -or $cv -is [long] -or $cv -is [bool])
    if ($scalar -and ($bv -ne $cv)) {
      $result.ValueDifferences += [pscustomobject]@{ Property=$p; Baseline=$bv; Candidate=$cv }
    }
  }
  return $result
}

# Helper to centralize writing failure JSON payloads
function Write-FailureJson {
  param(
    [Parameter(Mandatory)][string]$FailureJsonPath,
    [Parameter(Mandatory)][string]$Spec,
    [Parameter(Mandatory)][string]$SourcePath,
    [object[]]$Errors,
    [object[]]$LineErrors
  )
  $dir = Split-Path -Parent $FailureJsonPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $payload = [ordered]@{
    spec = $Spec
    path = (Resolve-Path -LiteralPath $SourcePath).Path
    timestamp = (Get-Date).ToString('o')
  }
  if ($Errors) { $payload.errors = @($Errors) }
  if ($LineErrors) { $payload.lineErrors = @($LineErrors) }
  ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $FailureJsonPath -Encoding UTF8
}

# Alias retained for potential backwards compat if earlier patches referenced it (no-op now)
Set-Alias -Name _OriginalAssertJsonShape -Value Assert-JsonShape -ErrorAction SilentlyContinue
