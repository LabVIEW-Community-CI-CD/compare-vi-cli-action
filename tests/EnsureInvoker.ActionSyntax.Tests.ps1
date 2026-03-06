Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_Pester5Guard.ps1')
[void](Assert-PesterV5OrNewer -Caller $PSCommandPath)

Describe 'ensure-invoker action syntax guard' -Tag 'Unit' {
  It 'avoids invalid variable interpolation patterns in composite run blocks' {
    $actionPath = Join-Path $PSScriptRoot '..' '.github' 'actions' 'ensure-invoker' 'action.yml'
    $content = Get-Content -LiteralPath $actionPath -Raw

    # In PowerShell double-quoted strings, "$i:" is a parser error. Require braced form.
    $content | Should -Not -Match '#\$[A-Za-z_][A-Za-z0-9_]*:'
    $content | Should -Match '#\$\{i\}:'
  }

  It 'dumps key invoker diagnostics when startup ping fails' {
    $actionPath = Join-Path $PSScriptRoot '..' '.github' 'actions' 'ensure-invoker' 'action.yml'
    $content = Get-Content -LiteralPath $actionPath -Raw

    $content | Should -Match 'Invoker ping failed; dumping invoker diagnostics'
    foreach ($name in @('boot.log','ready.json','requests-log.ndjson','heartbeat.ndjson','pid.txt')) {
      $pattern = [regex]::Escape($name)
      $content | Should -Match $pattern
    }
  }

  It 'invokes Wait-InvokerReady with named splatting to avoid positional binding drift' {
    $actionPath = Join-Path $PSScriptRoot '..' '.github' 'actions' 'ensure-invoker' 'action.yml'
    $content = Get-Content -LiteralPath $actionPath -Raw

    $content | Should -Match '\$waitArgs\s*=\s*@\{'
    $content | Should -Match 'Wait-InvokerReady\.ps1\s+@waitArgs'
    $content | Should -Not -Match 'Wait-InvokerReady\.ps1\s+@args'
  }
}
