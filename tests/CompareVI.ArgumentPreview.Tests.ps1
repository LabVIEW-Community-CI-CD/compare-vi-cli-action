Describe 'CompareVI argument preview' -Tag 'Unit' {
  BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'CompareVI.psm1') -Force
  }

  It 'builds correct command with quoted paths' {
    $base = Join-Path $TestDrive 'apple with space.vi'
    $head = Join-Path $TestDrive 'orange.vi'
    Set-Content -LiteralPath $base -Value 'x' -Encoding Ascii
    Set-Content -LiteralPath $head -Value 'y' -Encoding Ascii

    $cmd = Invoke-CompareVI -Base $base -Head $head -PreviewArgs
    $cmd | Should -Match 'LVCompare\.exe'
    $cmd | Should -Match ([regex]::Escape('"' + (Resolve-Path $base).Path + '"'))
    # Head may be unquoted if no spaces; accept either
    $cmd | Should -Match ([regex]::Escape((Resolve-Path $head).Path))
  }

  It 'accepts allowed flags and -lvpath value' {
    $base = Join-Path $TestDrive 'a.vi'; $head = Join-Path $TestDrive 'b.vi'
    Set-Content -LiteralPath $base -Value 'x'
    Set-Content -LiteralPath $head -Value 'y'

    $lv = 'C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe'
    $args = "-noattr -nofp -nofppos -nobd -nobdcosm -lvpath $lv"
    $cmd = Invoke-CompareVI -Base $base -Head $head -LvCompareArgs $args -PreviewArgs
    $cmd | Should -Match '\-noattr'
    $cmd | Should -Match '\-nofp'
    $cmd | Should -Match '\-nofppos'
    $cmd | Should -Match '\-nobd(?!\w)'
    $cmd | Should -Match '\-nobdcosm'
    # -lvpath target may appear quoted or unquoted in preview; accept either
    $pat = ('-lvpath\s+"?' + [regex]::Escape($lv) + '"?')
    $cmd | Should -Match $pat
  }

  It 'rejects invalid flags early' {
    $base = Join-Path $TestDrive 'a2.vi'; $head = Join-Path $TestDrive 'b2.vi'
    Set-Content -LiteralPath $base -Value 'x'
    Set-Content -LiteralPath $head -Value 'y'

  { Invoke-CompareVI -Base $base -Head $head -LvCompareArgs '-badflag' -PreviewArgs } | Should -Throw
  }
}
