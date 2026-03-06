Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'ensure-invoker action syntax guard' -Tag 'Unit' {
  It 'avoids invalid variable interpolation patterns in composite run blocks' {
    $actionPath = Join-Path $PSScriptRoot '..' '.github' 'actions' 'ensure-invoker' 'action.yml'
    $content = Get-Content -LiteralPath $actionPath -Raw

    # In PowerShell double-quoted strings, "$i:" is a parser error. Require braced form.
    $content | Should -Not -Match '#\$[A-Za-z_][A-Za-z0-9_]*:'
    $content | Should -Match '#\$\{i\}:'
  }
}
