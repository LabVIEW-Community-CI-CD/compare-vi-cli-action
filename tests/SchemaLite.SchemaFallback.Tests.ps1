Describe 'Invoke-JsonSchemaLite schema fallback' {
  It 'reloads schema when payload schema id differs from provided path' {
    $script = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $jsonPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'fixture-validation.json')).ProviderPath
    $manifestSchema = (Resolve-Path (Join-Path $PSScriptRoot '..' 'docs' 'schemas' 'fixture-manifest-v1.schema.json')).ProviderPath

    $output = & pwsh -NoLogo -NoProfile -File $script -JsonPath $jsonPath -SchemaPath $manifestSchema 2>&1
    $LASTEXITCODE | Should -Be 0
    ($output -join [Environment]::NewLine) | Should -Match '\[schema-lite\] notice: schema const mismatch'
    ($output -join [Environment]::NewLine) | Should -Match 'fixture-validation-v1\.schema\.json'
    $output | Should -Contain 'Schema-lite validation passed.'
  }
}
