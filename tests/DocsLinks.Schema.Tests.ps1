Describe 'Docs links schema' -Tag 'Unit' {
  It 'emits docs-links/v1 JSON and conforms to schema-lite' {
    $td = Join-Path $TestDrive 'docs'
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    $md = @('# Demo','', '[Missing](./nope.md)') -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $td 'Demo.md') -Value $md -Encoding UTF8
    $out = Join-Path $TestDrive 'links.json'
    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Check-DocsLinks.ps1') -Path $td -OutputJson $out -Quiet | Out-Null
    Test-Path -LiteralPath $out | Should -BeTrue
    & (Join-Path $root 'tools/Invoke-JsonSchemaLite.ps1') -JsonPath $out -SchemaPath (Join-Path $root 'docs/schemas/docs-links-v1.schema.json')
    $LASTEXITCODE | Should -Be 0
  }

  It 'accepts HttpTimeoutSec values provided as strings' {
    $td = Join-Path $TestDrive 'docs'
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    Set-Content -LiteralPath (Join-Path $td 'Demo.md') -Value '# Sample' -Encoding UTF8
    $root = (Get-Location).Path
    { & (Join-Path $root 'tools/Check-DocsLinks.ps1') -Path $td -HttpTimeoutSec '15' -Quiet } | Should -NotThrow
  }
}

