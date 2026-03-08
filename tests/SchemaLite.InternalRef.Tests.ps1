Describe 'Invoke-JsonSchemaLite internal $ref support' -Tag 'Unit' {
  It 'resolves root $ref into definitions and enforces required fields' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema.json'
    $validJsonPath = Join-Path $TestDrive 'valid.json'
    $invalidJsonPath = Join-Path $TestDrive 'invalid.json'

    @'
{
  "$ref": "#/definitions/root",
  "definitions": {
    "root": {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": { "type": "string" }
      },
      "additionalProperties": false
    }
  }
}
'@ | Set-Content -LiteralPath $schemaPath -Encoding utf8

    '{"name":"ok"}' | Set-Content -LiteralPath $validJsonPath -Encoding utf8
    '{}' | Set-Content -LiteralPath $invalidJsonPath -Encoding utf8

    & pwsh -NoLogo -NoProfile -File $script -JsonPath $validJsonPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0

    $output = & pwsh -NoLogo -NoProfile -File $script -JsonPath $invalidJsonPath -SchemaPath $schemaPath 2>&1
    $LASTEXITCODE | Should -Be 3
    ($output -join [Environment]::NewLine) | Should -Match "Missing required field 'name'"
  }

  It 'fails invalid session-index-v2 payloads that previously slipped past the root $ref' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'docs' 'schema' 'generated' 'session-index-v2.schema.json')).ProviderPath
    $invalidJsonPath = Join-Path $TestDrive 'session-index-v2.invalid.json'

    @'
{
  "schema": "session-index/v2",
  "schemaVersion": "2.0.0",
  "generatedAtUtc": "2026-03-08T01:00:00Z"
}
'@ | Set-Content -LiteralPath $invalidJsonPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script -JsonPath $invalidJsonPath -SchemaPath $schemaPath 2>&1
    $LASTEXITCODE | Should -Be 3
    ($output -join [Environment]::NewLine) | Should -Match "Missing required field 'run'"
  }
}
