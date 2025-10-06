Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Schema-lite enum and range validation' -Tag 'Unit' {
  It 'passes with allowed enum and within range' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $jsonFile = Join-Path $repoRoot 'tmp-enum-ok.json'
    $schemaFile = Join-Path $repoRoot 'tmp-enum.schema.json'

    @'
{"status":"ok","retryCount":3}
'@ | Set-Content -LiteralPath $jsonFile -Encoding utf8

    @'
{
  "type": "object",
  "required": ["status"],
  "additionalProperties": false,
  "properties": {
    "status": { "type": "string", "enum": ["ok","warn","error"] },
    "retryCount": { "type": "integer", "minimum": 0, "maximum": 5 }
  }
}
'@ | Set-Content -LiteralPath $schemaFile -Encoding utf8

    pwsh -NoLogo -NoProfile -File $script -JsonPath $jsonFile -SchemaPath $schemaFile | Out-Null
    $LASTEXITCODE | Should -Be 0
  }

  It 'fails when enum mismatch or out of range' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $jsonFile = Join-Path $repoRoot 'tmp-enum-bad.json'
    $schemaFile = Join-Path $repoRoot 'tmp-enum.schema.json'

    @'
{"status":"bad","retryCount":9}
'@ | Set-Content -LiteralPath $jsonFile -Encoding utf8

    @'
{
  "type": "object",
  "required": ["status"],
  "additionalProperties": false,
  "properties": {
    "status": { "type": "string", "enum": ["ok","warn","error"] },
    "retryCount": { "type": "integer", "minimum": 0, "maximum": 5 }
  }
}
'@ | Set-Content -LiteralPath $schemaFile -Encoding utf8

    pwsh -NoLogo -NoProfile -File $script -JsonPath $jsonFile -SchemaPath $schemaFile | Out-Null
    $LASTEXITCODE | Should -Be 3
  }
}
