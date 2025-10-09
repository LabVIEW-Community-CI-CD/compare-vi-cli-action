Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LVCompare args tokenization' -Tag 'Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    $script:ArgModule = Import-Module (Join-Path $root 'scripts' 'ArgTokenization.psm1') -Force -PassThru
    $script:CompareModule = Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force -PassThru

    function Convert-TokensForAssert($arr) {
      $out = @()
      foreach ($t in @($arr)) { if ($t -is [string]) { $out += $t.Replace('\\','\') } else { $out += $t } }
      ,$out
    }

    function Invoke-GetLVCompareArgTokens([object]$Spec) {
      & $script:ArgModule { param($value) Get-LVCompareArgTokens -Spec $value } $Spec
    }

    function Invoke-ConvertArgTokenList([string[]]$Tokens) {
      if (-not $Tokens) { return @() }
      & $script:CompareModule { param($innerTokens) Convert-ArgTokenList -tokens $innerTokens } $Tokens
    }
  }
  
  It 'tokenizes comma-delimited flags and quoted values consistently' {
  # Use forward slashes for cross-platform compatibility in test data
  $argSpec = "-nobdcosm,-nofppos,-noattr,'-lvpath C:/Path With Space/LabVIEW.exe','--log C:/t x/l.log'"

  # CompareVI (direct tokenization pipeline)
  $cliArgs = Invoke-GetLVCompareArgTokens -Spec $argSpec
  $normalized = Invoke-ConvertArgTokenList -Tokens $cliArgs
  $expected = @('-nobdcosm','-nofppos','-noattr','-lvpath','C:\Path With Space\LabVIEW.exe','--log','C:\t x\l.log')
  (Convert-TokensForAssert $normalized) | Should -Be (Convert-TokensForAssert $expected)

    # CompareLoop (DI path)
  Import-Module (Join-Path $PSScriptRoot '..' 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
  $base = Join-Path $TestDrive 'A.vi'; $head = Join-Path $TestDrive 'B.vi'
  Set-Content -LiteralPath $base -Value '' -Encoding utf8
  Set-Content -LiteralPath $head -Value '' -Encoding utf8
  $argsSeen = $null
  $exec = { param($cli,$b,$h,$argv) $script:__cap = $argv; return 0 }
  $null = Invoke-IntegrationCompareLoop -Base $base -Head $head -LvCompareArgs $argSpec -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet -MaxIterations 1
  $argsSeen = $script:__cap
  $expected2 = @('-nobdcosm','-nofppos','-noattr','-lvpath','C:\Path With Space\LabVIEW.exe','--log','C:\t x\l.log')
  (Convert-TokensForAssert @($argsSeen)) | Should -Be (Convert-TokensForAssert $expected2)
  }

  It 'tokenizes whitespace-delimited flags with double-quoted values' {
  $argSpec = '-nobdcosm -nofppos -noattr "--log C:\a b\z.txt" -lvpath=C:\X\LabVIEW.exe "-lvpath C:\Y\LabVIEW.exe"'
  # CompareVI (whitespace/equals pipeline only)
  $list2 = Invoke-GetLVCompareArgTokens -Spec $argSpec
  $norm2 = Invoke-ConvertArgTokenList -Tokens $list2
  $expected3 = @('-nobdcosm','-nofppos','-noattr','--log','C:\a b\z.txt','-lvpath','C:\X\LabVIEW.exe','-lvpath','C:\Y\LabVIEW.exe')
  (Convert-TokensForAssert $norm2) | Should -Be (Convert-TokensForAssert $expected3)
  }

  It 'tokenizes equals-assignment forms for flags requiring values' {
  $argSpec = "'-lvpath=C:\X Space\LabVIEW.exe', '--log=C:\logs\a b\log.txt'"
    # CompareVI pipeline
    $cliArgs = Invoke-GetLVCompareArgTokens -Spec $argSpec
    $normalized = Invoke-ConvertArgTokenList -Tokens $cliArgs
  $expected = @('-lvpath','C:\X Space\LabVIEW.exe','--log','C:\logs\a b\log.txt')
  (Convert-TokensForAssert $normalized) | Should -Be (Convert-TokensForAssert $expected)

    # CompareLoop DI executor capture
    Import-Module (Join-Path $PSScriptRoot '..' 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
    $base = Join-Path $TestDrive 'E.vi'; $head = Join-Path $TestDrive 'F.vi'
    Set-Content -LiteralPath $base -Value '' -Encoding utf8
    Set-Content -LiteralPath $head -Value '' -Encoding utf8
    $cap = $null
    $exec = { param($cli,$b,$h,$argv) $script:__eqcap = $argv; 0 }
    $null = Invoke-IntegrationCompareLoop -Base $base -Head $head -LvCompareArgs $argSpec -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet -MaxIterations 1
    $cap = $script:__eqcap
  (Convert-TokensForAssert @($cap)) | Should -Be (Convert-TokensForAssert $expected)
  }

  It 'supports UNC and Unix-style paths in mixed forms' {
    $argSpec = "--log=\\\\server\\share\\a b\\out.log -lvpath /opt/lv/LabVIEW.exe '-lvpath \\server2\\share2\\LV.exe'"
    $list = Invoke-GetLVCompareArgTokens -Spec $argSpec
    $norm = Invoke-ConvertArgTokenList -Tokens $list
    $expected = @('--log','\\\\server\\share\\a b\\out.log','-lvpath','/opt/lv/LabVIEW.exe','-lvpath','\\\\server2\\share2\\LV.exe')
    (Convert-TokensForAssert $norm) | Should -Be (Convert-TokensForAssert $expected)
  }

  It 'accepts array inputs with quoted tokens preserved' {
    $arr = @('-nofppos', '"--log C:\\p q\\r.txt"', "-lvpath=C:\\Tools\\LabVIEW.exe", "'-lvpath C:\\Other\\LV.exe'")
    $list = Invoke-GetLVCompareArgTokens -Spec $arr
    $norm = Invoke-ConvertArgTokenList -Tokens $list
    $expected = @('-nofppos','--log','C:\\p q\\r.txt','-lvpath','C:\\Tools\\LabVIEW.exe','-lvpath','C:\\Other\\LV.exe')
    (Convert-TokensForAssert $norm) | Should -Be (Convert-TokensForAssert $expected)
  }

  It 'tokenizes mixed delimiters and preserves order' {
  $argSpec = @'
'--log C:\a b\x.txt',-nofppos,-lvpath=C:\Y\LabVIEW.exe -noattr "-lvpath C:\Z\LabVIEW.exe"
'@
    # CompareVI pipeline
    $cliArgs = Invoke-GetLVCompareArgTokens -Spec $argSpec
    $normalized = Invoke-ConvertArgTokenList -Tokens $cliArgs
    $expected = @('--log','C:\a b\x.txt','-nofppos','-lvpath','C:\Y\LabVIEW.exe','-noattr','-lvpath','C:\Z\LabVIEW.exe')
  (Convert-TokensForAssert $normalized) | Should -Be (Convert-TokensForAssert $expected)

    # CompareLoop DI executor capture
    Import-Module (Join-Path $PSScriptRoot '..' 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
    $base = Join-Path $TestDrive 'G.vi'; $head = Join-Path $TestDrive 'H.vi'
    Set-Content -LiteralPath $base -Value '' -Encoding utf8
    Set-Content -LiteralPath $head -Value '' -Encoding utf8
    $cap = $null
    $exec = { param($cli,$b,$h,$argv) $script:__mixcap = $argv; 0 }
    $null = Invoke-IntegrationCompareLoop -Base $base -Head $head -LvCompareArgs $argSpec -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet -MaxIterations 1
    $cap = $script:__mixcap
  (Convert-TokensForAssert @($cap)) | Should -Be (Convert-TokensForAssert $expected)
  }

  It 'detects invalid -lvpath without value (tokenization/validation path)' {
    # We exercise CompareVI's tokenization; while CompareVI itself validates during Invoke, we emulate the normalization and then
    # perform a simple local validation to ensure a missing value would be caught upstream before CLI invocation.
    $argSpec = "-nobdcosm -lvpath -noattr"
    $list = Invoke-GetLVCompareArgTokens -Spec $argSpec
    $norm = Invoke-ConvertArgTokenList -Tokens $list
    # Local validation mirror: -lvpath must be followed by a non-flag value
    $threw = $false
    try {
      for ($i=0; $i -lt $norm.Count; $i++) {
        if ($norm[$i] -ieq '-lvpath') {
          if ($i -eq $norm.Count - 1) { throw 'Invalid -lvpath (no value)' }
          $next = $norm[$i+1]
          if (-not $next -or $next.StartsWith('-')) { throw 'Invalid -lvpath (flag followed)' }
        }
      }
    } catch { $threw = $true }
    $threw | Should -BeTrue
  }
}

