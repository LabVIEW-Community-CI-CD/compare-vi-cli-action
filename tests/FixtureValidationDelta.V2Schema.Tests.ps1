Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture validation delta schema v2 emission & bounds' -Tag 'Unit' {
  It 'emits v2 schema when switch used and validates within bounds' {
    function New-Snapshot([int]$missing,[int]$untracked,[int]$tooSmall) {
      [pscustomobject]@{
        ok = $true
        generatedAt = (Get-Date).ToString('o')
        summaryCounts = [pscustomobject]@{
          missing=$missing; untracked=$untracked; tooSmall=$tooSmall; hashMismatch=0; manifestError=0; duplicate=0; schema=0
        }
        issues = @()
      }
    }
    $diffScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Diff-FixtureValidationJson.ps1')).ProviderPath
    $schemaLite = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaV2 = (Resolve-Path (Join-Path $PSScriptRoot '..' 'docs' 'schemas' 'fixture-validation-delta-v2.schema.json')).ProviderPath
    Test-Path $diffScript | Should -BeTrue
    $base = New-Snapshot -missing 0 -untracked 0 -tooSmall 0
    $curr = New-Snapshot -missing 2 -untracked 0 -tooSmall 0
    $bPath = Join-Path $TestDrive 'base.json'; $cPath = Join-Path $TestDrive 'curr.json'
  $base | ConvertTo-Json -Depth 4 | Set-Content -Path $bPath -Encoding utf8
  $curr | ConvertTo-Json -Depth 4 | Set-Content -Path $cPath -Encoding utf8
    $outPath = Join-Path $TestDrive 'delta.json'
    & $diffScript -Baseline $bPath -Current $cPath -Output $outPath -UseV2Schema | Out-Null
  $deltaRaw = Get-Content $outPath -Raw
  $delta = $deltaRaw | ConvertFrom-Json
  $delta.schema | Should -Be 'fixture-validation-delta-v2'
  Write-Host "DEBUG delta generatedAt=$($delta.generatedAt) type=$([string]($delta.generatedAt.GetType().FullName))"
  & $schemaLite -JsonPath $outPath -SchemaPath $schemaV2 2>&1 | Tee-Object -Variable schemaLiteOut | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "DEBUG Delta JSON: $deltaRaw"; Write-Host ("DEBUG SchemaLite Output:`n{0}" -f ($schemaLiteOut -join "`n")) }
  $LASTEXITCODE | Should -Be 0
  }
  It 'fails schema-lite validation when out-of-range delta encountered' {
    function New-Snapshot([int]$missing,[int]$untracked,[int]$tooSmall) { [pscustomobject]@{ ok=$true; generatedAt=(Get-Date).ToString('o'); summaryCounts=[pscustomobject]@{ missing=$missing; untracked=$untracked; tooSmall=$tooSmall; hashMismatch=0; manifestError=0; duplicate=0; schema=0 }; issues=@() } }
    $schemaLite = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-JsonSchemaLite.ps1')).ProviderPath
    $schemaV2 = (Resolve-Path (Join-Path $PSScriptRoot '..' 'docs' 'schemas' 'fixture-validation-delta-v2.schema.json')).ProviderPath
    # Craft a delta JSON directly with out-of-range value ( > 1000 )
    $bad = [ordered]@{
      schema='fixture-validation-delta-v2'
      baselinePath='b.json'
      currentPath='c.json'
      generatedAt=(Get-Date).ToString('o')
      baselineOk=$true
      currentOk=$true
      deltaCounts=[pscustomobject]@{ missing=1500 }
      changes=@([pscustomobject]@{ category='missing'; baseline=0; current=1500; delta=1500 })
      newStructuralIssues=@()
      failOnNewStructuralIssue=$false
      willFail=$false
    } | ConvertTo-Json -Depth 5
    $badPath = Join-Path $TestDrive 'delta-bad.json'
    $bad | Set-Content -Path $badPath -Encoding utf8
    & $schemaLite -JsonPath $badPath -SchemaPath $schemaV2 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 3
  }
}
