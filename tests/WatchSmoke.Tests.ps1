Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Watch Smoke' -Tag 'WatchSmoke','Unit' {
  It 'runs a trivial assertion quickly' {
    1 | Should -Be 1
  }
}

