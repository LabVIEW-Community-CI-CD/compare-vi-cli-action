Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'SchemaLite date-time format validation' -Tag 'Unit' {
  It 'accepts valid RFC3339-ish ISO string' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema.json'
    '{"type":"object","properties":{"ts":{"type":"string","format":"date-time"}},"required":["ts"],"additionalProperties":false}' | Set-Content -Path $schemaPath -Encoding utf8
    $dataPath = Join-Path $TestDrive 'data.json'
    '{"ts":"2025-10-03T12:34:56"}' | Set-Content -Path $dataPath -Encoding utf8
    & $script -JsonPath $dataPath -SchemaPath $schemaPath | Out-Null
    $LASTEXITCODE | Should -Be 0
  }

  It 'rejects non-date-time string' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema.json'
    '{"type":"object","properties":{"ts":{"type":"string","format":"date-time"}},"required":["ts"],"additionalProperties":false}' | Set-Content -Path $schemaPath -Encoding utf8
    $dataPath = Join-Path $TestDrive 'bad.json'
    '{"ts":"not-a-date"}' | Set-Content -Path $dataPath -Encoding utf8
    & $script -JsonPath $dataPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }

  It 'accepts native DateTime value cast through ConvertTo-Json parse' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema.json'
    '{"type":"object","properties":{"ts":{"type":"string","format":"date-time"}},"required":["ts"],"additionalProperties":false}' | Set-Content -Path $schemaPath -Encoding utf8
    $obj = [pscustomobject]@{ ts = [DateTime]::Parse('2025-10-03T01:02:03') }
    $dataPath = Join-Path $TestDrive 'native.json'
    $obj | ConvertTo-Json -Depth 3 | Set-Content -Path $dataPath -Encoding utf8
    & $script -JsonPath $dataPath -SchemaPath $schemaPath | Out-Null
    $LASTEXITCODE | Should -Be 0
  }
}
