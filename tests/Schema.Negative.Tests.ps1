# Negative tests for JSON/NDJSON schema helper
# Verifies failure modes: invalid JSON line, missing required property, predicate failure

. "$PSScriptRoot/TestHelpers.Schema.ps1"

Describe 'Schema Helper Negative Cases' -Tag 'Unit' {

  It 'fails when a required property is missing (RunSummary spec)' {
    $tmp = Join-Path $TestDrive 'bad-run-summary.json'
    # schema requires 'schema' field; omit it
    '{"iterations":1,"diffCount":0}' | Set-Content -Path $tmp -Encoding UTF8
    { Assert-JsonShape -Path $tmp -Spec 'RunSummary' } | Should -Throw -ErrorId *
  }

  It 'fails when NDJSON contains invalid JSON line (LoopEvent spec)' {
    $tmp = Join-Path $TestDrive 'bad-events.ndjson'
    @(
      '{"schema":"loop-script-events-v1","type":"result","iterations":1}'
      '{BAD JSON LINE'
      '{"schema":"loop-script-events-v1","type":"result","iterations":2}'
    ) | Set-Content -Path $tmp -Encoding UTF8
    { Assert-NdjsonShapes -Path $tmp -Spec 'LoopEvent' } | Should -Throw -ErrorId *
  }

  It 'fails when a predicate check fails (negative number for iterations)' {
    $tmp = Join-Path $TestDrive 'bad-final-status.json'
    '{"schema":"loop-final-status-v1","timestamp":"2025-10-01T00:00:00Z","iterations":-5,"diffs":0,"errors":0,"succeeded":true,"averageSeconds":0.01,"totalSeconds":0.01,"percentiles":{},"histogram":null,"diffSummaryEmitted":false,"basePath":"VI1.vi","headPath":"VI2.vi"}' | Set-Content -Path $tmp -Encoding UTF8
    { Assert-JsonShape -Path $tmp -Spec 'FinalStatus' } | Should -Throw -ErrorId *
  }
}
