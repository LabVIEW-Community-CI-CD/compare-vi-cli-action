($__testDir = $null)
try { if ($PSCommandPath) { $__testDir = Split-Path -Parent $PSCommandPath } } catch {}
if (-not $__testDir) { try { $__testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $__testDir) { $__testDir = (Resolve-Path '.').Path }
. (Join-Path $__testDir '_TestPathHelper.ps1')

Describe 'RunnerInvoker single-compare gating and request log' -Tag 'Unit' {
  BeforeAll {
    $testDir = $null
    try { if ($PSCommandPath) { $testDir = Split-Path -Parent $PSCommandPath } } catch {}
    if (-not $testDir) { try { $testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
    if (-not $testDir) { $testDir = (Resolve-Path '.').Path }
    . (Join-Path $testDir '_TestPathHelper.ps1')
    $script:repoRoot = Resolve-RepoRoot
  }

  It 'allows one CompareVI preview then rejects subsequent requests when LVCI_SINGLE_COMPARE=1' {
    $modulePath = Join-Path (Join-Path (Join-Path $script:repoRoot 'tools') 'RunnerInvoker') 'RunnerInvoker.psm1'
    Test-Path -LiteralPath $modulePath | Should -BeTrue
    Import-Module $modulePath -Force

    $resultsDir = Join-Path $TestDrive 'invoker-single'
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
    $sentinel = Join-Path $TestDrive 'sentinel.stop'
    New-Item -ItemType File -Path $sentinel -Force | Out-Null
    $env:LVCI_SINGLE_COMPARE = '1'
    $env:LVCI_SINGLE_COMPARE_AUTOSTOP = '0'

    $job = Start-ThreadJob -ScriptBlock {
      param($mod,$res,$sent)
      Import-Module $mod -Force
      Start-InvokerLoop -PipeName 'test.pipe' -SentinelPath $sent -ResultsDir $res -PollIntervalMs 50
    } -ArgumentList $modulePath,$resultsDir,$sentinel

    Start-Sleep -Milliseconds 150

    $base = Join-Path $TestDrive 'base.vi'; $head = Join-Path $TestDrive 'head.vi'
    Set-Content -LiteralPath $base -Value 'A'
    Set-Content -LiteralPath $head -Value 'B'

    $argMap = @{ base=$base; head=$head; preview=$true }
    $resp1 = Invoke-RunnerRequest -ResultsDir $resultsDir -Verb 'CompareVI' -CommandArgs $argMap $resp1.ok | Should -BeTrue
    Test-Path -LiteralPath $resp1.result.execJsonPath | Should -BeTrue

    # Second request should be rejected
    $resp2 = Invoke-RunnerRequest -ResultsDir $resultsDir -Verb 'CompareVI' -CommandArgs $argMap $resp2.ok | Should -BeFalse
    [string]$resp2.error | Should -Match 'compare_already_handled'

    # Signal phase completion so the invoker loop exits on its own
    $phaseResp = Invoke-RunnerRequest -ResultsDir $resultsDir -Verb 'PhaseDone' $phaseResp.ok | Should -BeTrue
    $phaseResp.result.done | Should -BeTrue

    # Allow the invoker to remove the sentinel file (downstream trigger)
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and (Test-Path -LiteralPath $sentinel)) { Start-Sleep -Milliseconds 50 }
    (Test-Path -LiteralPath $sentinel) | Should -BeFalse

    # Request log should exist with at least 2 lines
    $reqLog = Join-Path $resultsDir '_invoker' 'requests-log.ndjson'
    Test-Path -LiteralPath $reqLog | Should -BeTrue
    ($lines = Get-Content -LiteralPath $reqLog) | Out-Null
    $lines.Count | Should -BeGreaterOrEqual 2

    # Collect the job before cleanup
    Wait-Job -Id $job.Id -Timeout 5 | Out-Null
    Receive-Job -Id $job.Id -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\LVCI_SINGLE_COMPARE -ErrorAction SilentlyContinue
    Remove-Item Env:\LVCI_SINGLE_COMPARE_AUTOSTOP -ErrorAction SilentlyContinue
  }
}

