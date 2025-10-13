# Tests for Strict mode and schema export

BeforeAll {
  . "$PSScriptRoot/TestHelpers.Schema.ps1"
}

Describe 'Schema Helper Strict Mode' -Tag 'Unit' {
  It 'fails when unexpected property present in Strict mode' {
    $tmp = Join-Path $TestDrive 'strict-final.json'
    '{"schema":"loop-final-status-v1","timestamp":"2025-10-01T00:00:00Z","iterations":0,"diffs":0,"errors":0,"succeeded":true,"unexpected":123}' | Set-Content -Path $tmp -Encoding UTF8
  { Assert-JsonShape -Path $tmp -Spec 'FinalStatus' -Strict } | Should -Throw -ErrorId *
  }
  It 'passes when same file validated non-strict' {
    $tmp = Join-Path $TestDrive 'non-strict-final.json'
    '{"schema":"loop-final-status-v1","timestamp":"2025-10-01T00:00:00Z","iterations":0,"diffs":0,"errors":0,"succeeded":true,"unexpected":123}' | Set-Content -Path $tmp -Encoding UTF8
    Assert-JsonShape -Path $tmp -Spec 'FinalStatus' | Should -BeTrue
  }
}

Describe 'Schema Helper Export-JsonShapeSchemas' -Tag 'Unit' {
  It 'exports schema files for all specs and enforces additionalProperties false' {
    $outDir = Join-Path $TestDrive 'schemas'
    $files = Export-JsonShapeSchemas -OutputDirectory $outDir
    # Expect one per current spec
    $specCount = $script:JsonShapeSpecs.Keys.Count
    ($files | Measure-Object).Count | Should -Be $specCount
    foreach ($f in $files) {
      $json = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json
      $json.additionalProperties | Should -BeFalse
      $json.required | Should -Not -BeNullOrEmpty
    }
  }
}
