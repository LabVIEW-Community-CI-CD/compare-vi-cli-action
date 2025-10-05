Describe 'ArgTokenizer managed parity' -Tag 'Unit' {
  BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'ArgTokenization.psm1') -Force
    $managed = Join-Path $PSScriptRoot '..' 'scripts' 'ArgTokenizer.Managed.psm1'
    . $managed
    $dll = Join-Path $PSScriptRoot '..' 'src' 'CompareVi.Shared' 'bin' 'Release' 'net8.0' 'CompareVi.Shared.dll'
    $haveDll = Test-Path -LiteralPath $dll
  }

  It 'tokenizes simple flags and values' -Skip:(-not $haveDll) {
    $s = "-a 1 -b 2 c"
    $ps  = Get-LVCompareArgTokenPattern
    $pt  = [regex]::Matches($s, $ps) | ForEach-Object { $_.Value }
    $mt  = Get-TokenizedArgsManaged -InputString $s
    $pt | Should -Be $mt
  }

  It 'normalizes -flag=value into flag value pair' -Skip:(-not $haveDll) {
    $tokens = @('-x=1','-y','2','z')
    $psNorm = Convert-ArgTokenList -tokens $tokens
    $mtNorm = Normalize-FlagValuePairsManaged -Tokens $tokens
    $psNorm | Should -Be $mtNorm
  }
}

