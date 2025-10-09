Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'SchemaLite - Watch Log NDJSON' -Tag 'Schema','Unit' {
  It 'validates each entry in tools/dashboard/samples/watch-log.ndjson' {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script = Join-Path $repo 'tools' 'Invoke-JsonSchemaLite.ps1'
    $ndjson = Join-Path $repo 'tools' 'dashboard' 'samples' 'watch-log.ndjson'
    $schema = Join-Path $repo 'docs' 'schemas' 'watch-log-item-v1.schema.json'

    Test-Path -LiteralPath $script | Should -BeTrue
    Test-Path -LiteralPath $ndjson | Should -BeTrue
    Test-Path -LiteralPath $schema | Should -BeTrue

    $buf = ''
    $lines = Get-Content -LiteralPath $ndjson
    foreach ($line in $lines) {
      if ([string]::IsNullOrWhiteSpace($line)) {
        if ($buf) {
          $tmp = New-TemporaryFile
          try {
            $buf | Set-Content -LiteralPath $tmp -Encoding UTF8
            & $script -JsonPath $tmp -SchemaPath $schema
            $LASTEXITCODE | Should -Be 0
          } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
          $buf = ''
        }
      } else {
        $buf += ($line + [Environment]::NewLine)
      }
    }
    if ($buf) {
      $tmp = New-TemporaryFile
      try {
        $buf | Set-Content -LiteralPath $tmp -Encoding UTF8
        & $script -JsonPath $tmp -SchemaPath $schema
        $LASTEXITCODE | Should -Be 0
      } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
  }
}

