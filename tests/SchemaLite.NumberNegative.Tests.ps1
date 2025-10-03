Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'SchemaLite number/integer negative cases' -Tag 'Unit' {
  It 'fails when integer field is non-numeric string' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema.json'
    '{"type":"object","properties":{"val":{"type":"integer"}},"required":["val"],"additionalProperties":false}' | Set-Content -Path $schemaPath -Encoding utf8
    $dataPath = Join-Path $TestDrive 'data.json'
    '{"val":"abc"}' | Set-Content -Path $dataPath -Encoding utf8
    & $script -JsonPath $dataPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }

  It 'fails when number field is non-numeric string' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema2.json'
    '{"type":"object","properties":{"ratio":{"type":"number"}},"required":["ratio"],"additionalProperties":false}' | Set-Content -Path $schemaPath -Encoding utf8
    $dataPath = Join-Path $TestDrive 'data2.json'
    '{"ratio":"NaNish"}' | Set-Content -Path $dataPath -Encoding utf8
    & $script -JsonPath $dataPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }

  It 'passes with valid numeric types' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaPath = Join-Path $TestDrive 'schema3.json'
    '{"type":"object","properties":{"i":{"type":"integer"},"n":{"type":"number"}},"required":["i","n"],"additionalProperties":false}' | Set-Content -Path $schemaPath -Encoding utf8
    $dataPath = Join-Path $TestDrive 'data3.json'
    '{"i":5,"n":1.25}' | Set-Content -Path $dataPath -Encoding utf8
    & $script -JsonPath $dataPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
  }
}
