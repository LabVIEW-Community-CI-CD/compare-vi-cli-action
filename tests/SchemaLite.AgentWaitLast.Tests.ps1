Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'SchemaLite - Agent Wait Last' -Tag 'Schema','Unit' {
  It 'validates tools/dashboard/samples/wait-last.json against schema' {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script = Join-Path $repo 'tools' 'Invoke-JsonSchemaLite.ps1'
    $json = Join-Path $repo 'tools' 'dashboard' 'samples' 'wait-last.json'
    $schema = Join-Path $repo 'docs' 'schemas' 'agent-wait-last-v1.schema.json'

    Test-Path -LiteralPath $script | Should -BeTrue
    Test-Path -LiteralPath $json | Should -BeTrue
    Test-Path -LiteralPath $schema | Should -BeTrue

    & $script -JsonPath $json -SchemaPath $schema
    $LASTEXITCODE | Should -Be 0
  }
}

