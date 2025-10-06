Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Delta schema v2 force flag' -Tag 'Unit' {
  It 'emits v2 schema when DELTA_FORCE_V2=true env is set (no switch)' {
    $diffScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Diff-FixtureValidationJson.ps1')).ProviderPath
    $schemaLite = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaV2 = (Resolve-Path (Join-Path $PSScriptRoot '..' 'docs' 'schemas' 'fixture-validation-delta-v2.schema.json')).ProviderPath
    $env:DELTA_FORCE_V2 = 'true'
    try {
      $base = [pscustomobject]@{ ok=$true; summaryCounts=[pscustomobject]@{ missing=0; untracked=0; tooSmall=0; hashMismatch=0; manifestError=0; duplicate=0; schema=0 }; issues=@() }
      $curr = [pscustomobject]@{ ok=$true; summaryCounts=[pscustomobject]@{ missing=1; untracked=0; tooSmall=0; hashMismatch=0; manifestError=0; duplicate=0; schema=0 }; issues=@() }
      $bPath = Join-Path $TestDrive 'b.json'; $cPath = Join-Path $TestDrive 'c.json'
      $base | ConvertTo-Json -Depth 4 | Set-Content -Path $bPath -Encoding utf8
      $curr | ConvertTo-Json -Depth 4 | Set-Content -Path $cPath -Encoding utf8
      $outPath = Join-Path $TestDrive 'delta.json'
      & $diffScript -Baseline $bPath -Current $cPath -Output $outPath | Out-Null
      $delta = Get-Content $outPath -Raw | ConvertFrom-Json
      $delta.schema | Should -Be 'fixture-validation-delta-v2'
      & $schemaLite -JsonPath $outPath -SchemaPath $schemaV2 2>&1 | Out-Null
      $LASTEXITCODE | Should -Be 0
    } finally {
      Remove-Item Env:DELTA_FORCE_V2 -ErrorAction SilentlyContinue
    }
  }
}
