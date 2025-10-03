Describe 'SchemaLite additionalProperties object-form' -Tag 'Unit' {
  It 'accepts extra properties matching additionalProperties spec (string enum)' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    Test-Path $script | Should -BeTrue
    $schema = [pscustomobject]@{
      type = 'object'
      properties = [pscustomobject]@{ fixed = [pscustomobject]@{ type='string' } }
      additionalProperties = [pscustomobject]@{ type='string'; enum=@('A','B','C') }
    } | ConvertTo-Json -Depth 6
    $dataPath = Join-Path $TestDrive 'data.json'
    '{"fixed":"ok","x":"A","y":"B"}' | Set-Content -Path $dataPath -Encoding utf8
    $schemaPath = Join-Path $TestDrive 'schema.json'
    $schema | Set-Content -Path $schemaPath -Encoding utf8
  & $script -JsonPath $dataPath -SchemaPath $schemaPath | Out-Null
  $LASTEXITCODE | Should -Be 0
  }

  It 'fails when extra property violates enum' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schema = [pscustomobject]@{
      type = 'object'
      properties = [pscustomobject]@{ fixed = [pscustomobject]@{ type='string' } }
      additionalProperties = [pscustomobject]@{ type='string'; enum=@('A','B','C') }
    } | ConvertTo-Json -Depth 6
    $dataPath = Join-Path $TestDrive 'data.json'
    '{"fixed":"ok","x":"Z"}' | Set-Content -Path $dataPath -Encoding utf8
    $schemaPath = Join-Path $TestDrive 'schema.json'
    $schema | Set-Content -Path $schemaPath -Encoding utf8
  & $script -JsonPath $dataPath -SchemaPath $schemaPath 2>&1 | Out-Null
  $LASTEXITCODE | Should -Be 3
  }

  It 'validates numeric bounds on additional properties' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schema = [pscustomobject]@{
      type='object'
      additionalProperties = [pscustomobject]@{ type='integer'; minimum=0; maximum=10 }
    } | ConvertTo-Json -Depth 6
    $okPath = Join-Path $TestDrive 'ok.json'
    '{"a":0,"b":10,"c":5}' | Set-Content -Path $okPath -Encoding utf8
    $schemaPath = Join-Path $TestDrive 'schema.json'
    $schema | Set-Content -Path $schemaPath -Encoding utf8
    & $script -JsonPath $okPath -SchemaPath $schemaPath | Out-Null
    $LASTEXITCODE | Should -Be 0

    $badPath = Join-Path $TestDrive 'bad.json'
    '{"a":-1,"b":11}' | Set-Content -Path $badPath -Encoding utf8
    & $script -JsonPath $badPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }

  It 'recursively validates object additionalProperties' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schema = [pscustomobject]@{
      type='object'
      additionalProperties = [pscustomobject]@{
        type='object'
        properties = [pscustomobject]@{
          kind = [pscustomobject]@{ type='string'; enum=@('alpha','beta') }
        }
        required = @('kind')
        additionalProperties = $false
      }
    } | ConvertTo-Json -Depth 10
  $schemaPath = Join-Path $TestDrive 'schema.json'
  $schema | Set-Content -Path $schemaPath -Encoding utf8
  $okPath = Join-Path $TestDrive 'ok.json'
  '{"x":{"kind":"alpha"},"y":{"kind":"beta"}}' | Set-Content -Path $okPath -Encoding utf8
  & $script -JsonPath $okPath -SchemaPath $schemaPath | Out-Null
    $LASTEXITCODE | Should -Be 0
  $badPath = Join-Path $TestDrive 'bad.json'
  '{"x":{"kind":"alpha","extra":1}}' | Set-Content -Path $badPath -Encoding utf8
  & $script -JsonPath $badPath -SchemaPath $schemaPath 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }
}
