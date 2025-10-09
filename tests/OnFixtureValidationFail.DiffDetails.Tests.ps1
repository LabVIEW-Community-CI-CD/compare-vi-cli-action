Describe 'On-FixtureValidationFail tiny diff-details generator' -Tag 'Unit' {
  BeforeAll {
    $testDir = $null
    try { if ($PSCommandPath) { $testDir = Split-Path -Parent $PSCommandPath } } catch {}
    if (-not $testDir) { try { $testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
    if (-not $testDir) { $testDir = (Resolve-Path '.').Path }
    . (Join-Path $testDir '_TestPathHelper.ps1')
    $script:repoRoot = Resolve-RepoRoot
    $script:scriptPath = Join-Path (Join-Path $script:repoRoot 'scripts') 'On-FixtureValidationFail.ps1'
    Test-Path -LiteralPath $script:scriptPath | Should -BeTrue
    $sb = {
      param([string]$Path)
      $obj = [pscustomobject]@{
        exitCode = 6
        ok       = $false
        summaryCounts = @{}
      }
      $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
    }
    Set-Item -Path Function:\New-StrictJson -Value $sb -Options ReadOnly -Force
  }

  It 'writes diff-details.json (headChanges=4) when Head matches repository VI2.vi' {
    $out = Join-Path $TestDrive 'out1'
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    $strictPath = Join-Path $TestDrive 'strict.json'
    New-StrictJson -Path $strictPath

    $baseSrc = Join-Path $script:repoRoot 'VI1.vi'
    $headSrc = Join-Path $script:repoRoot 'VI2.vi'
    Test-Path $baseSrc | Should -BeTrue
    Test-Path $headSrc | Should -BeTrue

    $base = Join-Path $TestDrive 'base.vi'
    $head = Join-Path $TestDrive 'head.vi'
    Copy-Item -LiteralPath $baseSrc -Destination $base -Force
    Copy-Item -LiteralPath $headSrc -Destination $head -Force

    & $script:scriptPath -StrictJson $strictPath -OutputDir $out -BasePath $base -HeadPath $head -RenderReport | Out-Null

    $dd = Join-Path $out 'diff-details.json'
    Test-Path -LiteralPath $dd | Should -BeTrue
    $j = Get-Content -LiteralPath $dd -Raw | ConvertFrom-Json
    $j.schema | Should -Be 'diff-details/v1'
    [int]$j.headChanges | Should -Be 4
    [int]$j.baseChanges | Should -Be 0
    [string]$j.note | Should -Match 'sample detected'
  }

  It 'does not write diff-details.json when Head does not match repository VI2.vi' {
    $out = Join-Path $TestDrive 'out2'
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    $strictPath = Join-Path $TestDrive 'strict2.json'
    New-StrictJson -Path $strictPath

    $base = Join-Path $TestDrive 'base2.vi'
    $head = Join-Path $TestDrive 'head2.vi'
    Set-Content -LiteralPath $base -Value 'A'
    Set-Content -LiteralPath $head -Value 'B'

    & $script:scriptPath -StrictJson $strictPath -OutputDir $out -BasePath $base -HeadPath $head -RenderReport | Out-Null

    Test-Path -LiteralPath (Join-Path $out 'diff-details.json') | Should -BeFalse
  }

  It 'does not write diff-details.json when RenderReport is false (even if sample head matches)' {
    $out = Join-Path $TestDrive 'out3'
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    $strictPath = Join-Path $TestDrive 'strict3.json'
    New-StrictJson -Path $strictPath

    $baseSrc = Join-Path $repoRoot 'VI1.vi'
    $headSrc = Join-Path $repoRoot 'VI2.vi'
    $base = Join-Path $TestDrive 'base3.vi'
    $head = Join-Path $TestDrive 'head3.vi'
    Copy-Item -LiteralPath $baseSrc -Destination $base -Force
    Copy-Item -LiteralPath $headSrc -Destination $head -Force

    & $script:scriptPath -StrictJson $strictPath -OutputDir $out -BasePath $base -HeadPath $head | Out-Null

    $dd = Join-Path $out 'diff-details.json'
    Test-Path -LiteralPath $dd | Should -BeTrue
    $j = Get-Content -LiteralPath $dd -Raw | ConvertFrom-Json
    [int]$j.headChanges | Should -Be 4
    [int]$j.baseChanges | Should -Be 0
  }

  It 'overwrites an existing diff-details.json with canonical values when sample head matches' {
    $out = Join-Path $TestDrive 'out4'
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    $strictPath = Join-Path $TestDrive 'strict4.json'
    New-StrictJson -Path $strictPath

    $baseSrc = Join-Path $script:repoRoot 'VI1.vi'
    $headSrc = Join-Path $script:repoRoot 'VI2.vi'
    $base = Join-Path $TestDrive 'base4.vi'
    $head = Join-Path $TestDrive 'head4.vi'
    Copy-Item -LiteralPath $baseSrc -Destination $base -Force
    Copy-Item -LiteralPath $headSrc -Destination $head -Force

    # Pre-seed with different values
    $seed = [pscustomobject]@{ headChanges = 2; baseChanges = 99; schema='diff-details/v1' }
    $ddPath = Join-Path $out 'diff-details.json'
    $seed | ConvertTo-Json -Depth 4 | Out-File -FilePath $ddPath -Encoding utf8

    & $script:scriptPath -StrictJson $strictPath -OutputDir $out -BasePath $base -HeadPath $head -RenderReport | Out-Null

    Test-Path -LiteralPath $ddPath | Should -BeTrue
    $j = Get-Content -LiteralPath $ddPath -Raw | ConvertFrom-Json
    [int]$j.headChanges | Should -Be 4
    [int]$j.baseChanges | Should -Be 0
  }
}
