($__testDir = $null)
try { if ($PSCommandPath) { $__testDir = Split-Path -Parent $PSCommandPath } } catch {}
if (-not $__testDir) { try { $__testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $__testDir) { $__testDir = (Resolve-Path '.').Path }
. (Join-Path $__testDir '_TestPathHelper.ps1')

Describe 'CompareVI single-run diff details' -Tag 'Unit' {
  BeforeAll {
    $testDir = $null
    try { if ($PSCommandPath) { $testDir = Split-Path -Parent $PSCommandPath } } catch {}
    if (-not $testDir) { try { $testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
    if (-not $testDir) { $testDir = (Resolve-Path '.').Path }
    . (Join-Path $testDir '_TestPathHelper.ps1')
    $script:repoRoot = Resolve-RepoRoot
  }
  It 'reads diff-details.json and reports 4 head changes' {
    $td = $TestDrive
    $out = Join-Path $td 'out'
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    # Synthetic exec JSON (represents a single LVCompare run)
    $exec = [pscustomobject]@{
      schema      = 'compare-exec/v1'
      generatedAt = (Get-Date).ToString('o')
      cliPath     = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
      command     = 'LVCompare.exe "C:\\tmp\\base.vi" "C:\\tmp\\head.vi" -nobdcosm -nofppos -noattr'
      exitCode    = 1
      diff        = $true
      cwd         = $td
      duration_s  = 0.123
      base        = 'C:\\tmp\\base.vi'
      head        = 'C:\\tmp\\head.vi'
    }
    $execPath = Join-Path $out 'compare-exec.json'
    $exec | ConvertTo-Json -Depth 6 | Out-File -FilePath $execPath -Encoding utf8

    # Diff details: exactly 4 head changes
    $details = [pscustomobject]@{ headChanges = 4; baseChanges = 0 }
    $ddPath = Join-Path $out 'diff-details.json'
    $details | ConvertTo-Json -Depth 4 | Out-File -FilePath $ddPath -Encoding utf8

    # Render report and assert presence of head changes line
    $htmlOut = Join-Path $out 'compare-report.html'
    $render = Join-Path (Join-Path $script:repoRoot 'scripts') 'Render-CompareReport.ps1'
    & $render `
      -Command $exec.command -ExitCode $exec.exitCode -Diff 'true' -CliPath $exec.cliPath `
      -OutputPath $htmlOut -DurationSeconds $exec.duration_s -ExecJsonPath $execPath | Out-Null

    Test-Path -LiteralPath $htmlOut | Should -BeTrue
    $html = Get-Content -LiteralPath $htmlOut -Raw
    $html | Should -Match '<div class="key">Head Changes</div><div class="value">4</div>'
  }
}
