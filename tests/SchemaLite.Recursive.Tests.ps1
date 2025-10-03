Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Schema-lite recursive validation' -Tag 'Unit' {
  It 'fails when nested required field missing' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $tmpJson = Join-Path $repoRoot 'tmp-nested.json'
    $tmpSchema = Join-Path $repoRoot 'tmp-nested.schema.json'

    @'
{
  "parent": {
    "child": { "leaf": "value" }
  }
}
'@ | Set-Content -LiteralPath $tmpJson -Encoding utf8

    @'
{
  "type": "object",
  "required": ["parent"],
  "additionalProperties": false,
  "properties": {
    "parent": {
      "type": "object",
      "required": ["child"],
      "additionalProperties": false,
      "properties": {
        "child": {
          "type": "object",
          "required": ["leaf","missingLeaf"],
          "additionalProperties": false,
          "properties": {
            "leaf": { "type": "string" },
            "missingLeaf": { "type": "string" }
          }
        }
      }
    }
  }
}
'@ | Set-Content -LiteralPath $tmpSchema -Encoding utf8

    pwsh -NoLogo -NoProfile -File $script -JsonPath $tmpJson -SchemaPath $tmpSchema 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }
}
