Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Report HTML embeds LVCompare flags' -Tag 'Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force
    $script:render = (Join-Path $root 'scripts' 'Render-CompareReport.ps1')

    # Avoid filesystem checks for Resolve-Cli
    Mock -CommandName Resolve-Cli -ModuleName CompareVI -MockWith { param($Explicit,$PreferredBitness) 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe' }

    $script:execZero = { param($cli,$b,$h,$argv) return 0 }

    function New-ExecWithArgs([string]$argSpec) {
      $vis = Join-Path $TestDrive ('vis-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $vis -Force | Out-Null
      $base = Join-Path $vis 'a.vi'
      $head = Join-Path $vis 'b.vi'
      Set-Content -LiteralPath $base -Value '' -Encoding utf8
      Set-Content -LiteralPath $head -Value 'x' -Encoding utf8
      $execDir = Join-Path $TestDrive ('exec-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $execDir -Force | Out-Null
      $execPath = Join-Path $execDir 'compare-exec.json'
      $null = Invoke-CompareVI -Base $base -Head $head -LvCompareArgs $argSpec -FailOnDiff:$false -Executor $script:execZero -CompareExecJsonPath $execPath
      if (-not (Test-Path -LiteralPath $execPath)) { throw "compare-exec.json missing at: $execPath" }
      ,@{ execPath = $execPath; execDir = $execDir }
    }

    function Render-And-GetHtml([hashtable]$execInfo, [string]$outName) {
      $outPath = Join-Path $execInfo.execDir $outName
      # Satisfy mandatory params with stubs; ExecJson overrides internally
      $stubCmd = 'LVCompare A.vi B.vi'
      pwsh -NoLogo -NoProfile -File $script:render -Command $stubCmd -ExitCode 0 -Diff 'false' -CliPath 'C:\\dummy\\LVCompare.exe' -ExecJsonPath $execInfo.execPath -OutputPath $outPath | Out-Null
      if (-not (Test-Path -LiteralPath $outPath)) { throw "report missing: $outPath" }
      return (Get-Content -LiteralPath $outPath -Raw)
    }
  }

  It 'HTML contains -noattr' {
    $exec = New-ExecWithArgs '-noattr'
    $html = Render-And-GetHtml $exec 'report.html'
    $html | Should -Match '-noattr'
  }

  It 'HTML contains -nofp' {
    $exec = New-ExecWithArgs '-nofp'
    $html = Render-And-GetHtml $exec 'report.html'
    $html | Should -Match '-nofp'
  }

  It 'HTML contains -nofppos' {
    $exec = New-ExecWithArgs '-nofppos'
    $html = Render-And-GetHtml $exec 'report.html'
    $html | Should -Match '-nofppos'
  }

  It 'HTML contains -nobd' {
    $exec = New-ExecWithArgs '-nobd'
    $html = Render-And-GetHtml $exec 'report.html'
    $html | Should -Match '-nobd(\s|&)' # tolerate HTML context
  }

  It 'HTML contains -nobdcosm' {
    $exec = New-ExecWithArgs '-nobdcosm'
    $html = Render-And-GetHtml $exec 'report.html'
    $html | Should -Match '-nobdcosm'
  }

  It 'HTML contains -lvpath and path leaf' {
    $lv = 'C:\\Path With Space\\LabVIEW.exe'
    $exec = New-ExecWithArgs ("-lvpath=$lv")
    $html = Render-And-GetHtml $exec 'report.html'
    $html | Should -Match '-lvpath'
    $html | Should -Match 'LabVIEW.exe'
  }
}
