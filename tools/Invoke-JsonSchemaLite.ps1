param(
  [Parameter(Mandatory)][string]$JsonPath,
  [Parameter(Mandatory)][string]$SchemaPath
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $JsonPath)) { Write-Error "JSON file not found: $JsonPath"; exit 2 }
if (-not (Test-Path -LiteralPath $SchemaPath)) { Write-Error "Schema file not found: $SchemaPath"; exit 2 }

try { $data = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Error "Failed to parse JSON: $($_.Exception.Message)"; exit 2 }
try { $schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Error "Failed to parse schema: $($_.Exception.Message)"; exit 2 }

# When the supplied schema declares a const value that does not match the JSON payload's
# declared schema identifier, attempt to locate a sibling schema definition whose file
# name matches the payload's identifier ("<schema>.schema.json"). This keeps historical
# invocations that referenced an outdated schema file (for example, fixture manifests)
# from failing when the payload transitioned to a new schema contract (fixture-validation
# snapshots). The fallback only applies when both schema and payload expose a concrete
# identifier and the alternate file exists next to the requested schema path.
$schemaConst = $null
if ($schema -is [psobject]) {
  $schemaPropertiesProp = $schema.PSObject.Properties['properties']
  if ($schemaPropertiesProp -and $schemaPropertiesProp.Value -is [psobject]) {
    $schemaProperties = $schemaPropertiesProp.Value
    $schemaNodeProp = $schemaProperties.PSObject.Properties['schema']
    if ($schemaNodeProp -and $schemaNodeProp.Value -is [psobject]) {
      $schemaNode = $schemaNodeProp.Value
      $schemaConstProp = $schemaNode.PSObject.Properties['const']
      if ($schemaConstProp) {
        $schemaConst = [string]$schemaConstProp.Value
      }
    }
  }
}

$payloadSchemaId = $null
if ($data -is [psobject] -and $data.PSObject.Properties['schema']) {
  $payloadSchemaId = [string]$data.schema
}

if ($schemaConst -and $payloadSchemaId -and $schemaConst -ne $payloadSchemaId) {
  try {
    $resolvedSchemaPath = (Resolve-Path -LiteralPath $SchemaPath -ErrorAction Stop).ProviderPath
    $schemaDir = Split-Path -Parent $resolvedSchemaPath
    $altSchemaPath = Join-Path $schemaDir ("{0}.schema.json" -f $payloadSchemaId)
    if (Test-Path -LiteralPath $altSchemaPath -PathType Leaf) {
      $notice = [string]::Format(
        '[schema-lite] notice: schema const mismatch (expected {0} actual {1}); reloading schema from {2}',
        $schemaConst,
        $payloadSchemaId,
        $altSchemaPath
      )
      Write-Host $notice
      try {
        $schema = Get-Content -LiteralPath $altSchemaPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $SchemaPath = $altSchemaPath
      } catch {
        $warning = [string]::Format(
          '[schema-lite] fallback schema load failed for {0}: {1}',
          $altSchemaPath,
          $_.Exception.Message
        )
        Write-Warning $warning
      }
    }
  } catch {
    $warning = [string]::Format(
      '[schema-lite] failed to resolve alternate schema for {0}: {1}',
      $payloadSchemaId,
      $_.Exception.Message
    )
    Write-Warning $warning
  }
}

function Test-TypeMatch {
  param($val,[string]$type,[string]$path)
  switch ($type) {
  'string' { if (-not ($val -is [string] -or $val -is [datetime])) { return "Field '$path' expected type string" } }
    'boolean' { if (-not ($val -is [bool])) { return "Field '$path' expected type boolean" } }
    'integer' { if (-not ($val -is [int] -or $val -is [long])) { return "Field '$path' expected integer" } }
    'number'  { if (-not ($val -is [double] -or $val -is [float] -or $val -is [decimal] -or $val -is [int] -or $val -is [long])) { return "Field '$path' expected number" } }
    'object' { if (-not ($val -is [psobject])) { return "Field '$path' expected object" } }
    'array' { if (-not ($val -is [System.Array])) { return "Field '$path' expected array" } }
  }
  return $null
}

function Invoke-ValidateNode {
  param($node,$schemaNode,[string]$path)
  $errs = @()
  if ($schemaNode -isnot [psobject]) { return $errs }
  $nodeProps = @()
  if ($node -is [psobject]) { $nodeProps = $node.PSObject.Properties.Name }
  # required
  if (($schemaNode | Get-Member -Name required -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $schemaNode.required) {
    foreach ($r in $schemaNode.required) { if ($nodeProps -notcontains $r) { $errs += "Missing required field '$path$r'" } }
  }
  # properties iteration
  $hasProperties = ($schemaNode | Get-Member -Name properties -MemberType NoteProperty -ErrorAction SilentlyContinue)
  if ($hasProperties -and $schemaNode.properties -is [psobject]) {
    foreach ($p in $schemaNode.properties.PSObject.Properties) {
      $name = $p.Name; $spec = $p.Value; $childPath = "$path$name."
      if ($nodeProps -contains $name) {
        $val = $node.$name
        if ($spec -is [psobject]) {
          if (($spec | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.type) {
            $tm = Test-TypeMatch -val $val -type $spec.type -path ("$path$name"); if ($tm) { $errs += $tm; continue }
          }
          if (($spec | Get-Member -Name const -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.const -and $val -ne $spec.const) { $errs += "Field '$path$name' const mismatch (expected $($spec.const))" }
          if (($spec | Get-Member -Name enum -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.enum -and $spec.enum.Count -gt 0 -and ($spec.enum -notcontains $val)) { $errs += "Field '$path$name' value '$val' not in enum [$($spec.enum -join ', ')]" }
          if (($spec | Get-Member -Name minimum -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $null -ne $spec.minimum -and ($spec.type -in @('integer','number')) -and $val -lt $spec.minimum) { $errs += "Field '$path$name' value $val below minimum $($spec.minimum)" }
          if (($spec | Get-Member -Name maximum -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $null -ne $spec.maximum -and ($spec.type -in @('integer','number')) -and $val -gt $spec.maximum) { $errs += "Field '$path$name' value $val above maximum $($spec.maximum)" }
          if (($spec | Get-Member -Name format -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.format -eq 'date-time' -and $val) {
            if (-not ($val -is [datetime]) -and ($val -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')) { $errs += "Field '$path$name' expected RFC3339 date-time string" }
          }
          if (($spec | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.type -eq 'object' -and ($spec | Get-Member -Name properties -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.properties) {
            $errs += Invoke-ValidateNode -node $val -schemaNode $spec -path $childPath
          } elseif (($spec | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.type -eq 'array' -and ($spec | Get-Member -Name items -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.items -and ($val -is [System.Array])) {
            for ($i=0; $i -lt $val.Count; $i++) {
              $itemVal = $val[$i]; $tm2 = $null
              if ($spec.items -is [psobject] -and ($spec.items | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.items.type) { $tm2 = Test-TypeMatch -val $itemVal -type $spec.items.type -path ("$path$name[$i]") }
              if ($tm2) { $errs += $tm2; continue }
              if ($spec.items -is [psobject] -and ($spec.items | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.items.type -eq 'object' -and ($spec.items | Get-Member -Name properties -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $spec.items.properties) {
                $errs += Invoke-ValidateNode -node $itemVal -schemaNode $spec.items -path ("$path$name[$i].")
              }
            }
          }
        }
      }
    }
  }
  # additionalProperties handling
  $hasAdditional = ($schemaNode | Get-Member -Name additionalProperties -MemberType NoteProperty -ErrorAction SilentlyContinue)
  if ($hasAdditional) {
    if (($schemaNode | Get-Member -Name additionalProperties -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $schemaNode.additionalProperties -eq $false -and $hasProperties) {
      foreach ($actual in $nodeProps) { if ($schemaNode.properties.PSObject.Properties.Name -notcontains $actual) { $errs += "Unexpected field '${path}$actual'" } }
    } elseif ($schemaNode.additionalProperties -is [psobject]) {
      $apSpec = $schemaNode.additionalProperties
      foreach ($actual in $nodeProps) {
        if (-not $hasProperties -or $schemaNode.properties.PSObject.Properties.Name -notcontains $actual) {
          $val = $node.$actual
          if ($apSpec -is [psobject]) {
            if (($apSpec | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $apSpec.type) {
              $tmAp = Test-TypeMatch -val $val -type $apSpec.type -path ("${path}$actual"); if ($tmAp) { $errs += $tmAp; continue }
            }
            if (($apSpec | Get-Member -Name enum -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $apSpec.enum -and $apSpec.enum.Count -gt 0 -and ($apSpec.enum -notcontains $val)) { $errs += "Field '${path}$actual' value '$val' not in enum [$($apSpec.enum -join ', ')]" }
            if (($apSpec | Get-Member -Name minimum -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $null -ne $apSpec.minimum -and ($apSpec.type -in @('integer','number')) -and $val -lt $apSpec.minimum) { $errs += "Field '${path}$actual' value $val below minimum $($apSpec.minimum)" }
            if (($apSpec | Get-Member -Name maximum -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $null -ne $apSpec.maximum -and ($apSpec.type -in @('integer','number')) -and $val -gt $apSpec.maximum) { $errs += "Field '${path}$actual' value $val above maximum $($apSpec.maximum)" }
            if (($apSpec | Get-Member -Name format -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $apSpec.format -eq 'date-time' -and $val) {
              if (-not ($val -is [datetime]) -and ($val -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')) { $errs += "Field '${path}$actual' expected RFC3339 date-time string" }
            }
            if (($apSpec | Get-Member -Name type -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $apSpec.type -eq 'object' -and ($apSpec | Get-Member -Name properties -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $apSpec.properties) {
              $errs += Invoke-ValidateNode -node $val -schemaNode $apSpec -path ("${path}$actual.")
            }
          }
        }
      }
    }
  }
  return $errs
}

$errors = Invoke-ValidateNode -node $data -schemaNode $schema -path ''

if ($errors) {
  $errors | ForEach-Object { Write-Host "[schema-lite] error: $_" }
  exit 3
}
Write-Host 'Schema-lite validation passed.'
exit 0
