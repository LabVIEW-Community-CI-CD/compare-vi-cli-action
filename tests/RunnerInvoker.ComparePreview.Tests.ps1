($__testDir = $null)
try { if ($PSCommandPath) { $__testDir = Split-Path -Parent $PSCommandPath } } catch {}
if (-not $__testDir) { try { $__testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $__testDir) { $__testDir = (Resolve-Path '.').Path }
. (Join-Path $__testDir '_TestPathHelper.ps1')

Describe 'RunnerInvoker CompareVI preview path' -Tag 'Unit' {
  BeforeAll {
    $testDir = $null
    try { if ($PSCommandPath) { $testDir = Split-Path -Parent $PSCommandPath } } catch {}
    if (-not $testDir) { try { $testDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
    if (-not $testDir) { $testDir = (Resolve-Path '.').Path }
    . (Join-Path $testDir '_TestPathHelper.ps1')
    $script:repoRoot   = Resolve-RepoRoot
    $script:modulePath = Join-Path (Join-Path (Join-Path $script:repoRoot 'tools') 'RunnerInvoker') 'RunnerInvoker.psm1'
    Test-Path -LiteralPath $script:modulePath | Should -BeTrue
    Import-Module $script:modulePath -Force
  }

  It 'serves preview requests and logs the lifecycle (single compare aware)' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $sentinel = Join-Path $resultsDir 'sentinel.stop'
    New-Item -ItemType File -Path $sentinel -Force | Out-Null

    $job = Start-ThreadJob -ScriptBlock {
      param($modulePath,$results,$sentinelPath)
      Import-Module $modulePath -Force
      Start-InvokerLoop -PipeName 'preview.pipe' -SentinelPath $sentinelPath -ResultsDir $results -PollIntervalMs 50
    } -ArgumentList $script:modulePath,$resultsDir,$sentinel

    try {
      $invokerDir = Join-Path $resultsDir '_invoker'
      $ready = $false
      for ($i = 0; $i -lt 40; $i++) {
        if (Test-Path -LiteralPath $invokerDir) { $ready = $true; break }
        Start-Sleep -Milliseconds 50
      }
      $ready | Should -BeTrue

      $base = Join-Path $TestDrive 'base.vi'
      $head = Join-Path $TestDrive 'head.vi'
      Set-Content -LiteralPath $base -Value 'A'
      Set-Content -LiteralPath $head -Value 'B'

      $payload = @{ base = $base; head = $head; preview = $true }
      $resp = Invoke-RunnerRequest -ResultsDir $resultsDir -Verb 'CompareVI' -CommandArgs $payload $resp.ok | Should -BeTrue
      $resp.result.execJsonPath | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $resp.result.execJsonPath | Should -BeTrue
      $exec = Get-Content -LiteralPath $resp.result.execJsonPath -Raw | ConvertFrom-Json -Depth 6
      $exec.command | Should -Match ([regex]::Escape((Resolve-Path $base).Path))
      $exec.command | Should -Match ([regex]::Escape((Resolve-Path $head).Path))

      $requestLog = Join-Path $invokerDir 'requests-log.ndjson'
      $entries = Get-Content -LiteralPath $requestLog | ForEach-Object { $_ | ConvertFrom-Json }
      ($entries | Where-Object stage -eq 'dispatch_preview') | Should -Not -BeNullOrEmpty
      ($entries | Where-Object stage -eq 'result_ready')     | Should -Not -BeNullOrEmpty
      ($entries | Where-Object stage -eq 'completed')        | Should -Not -BeNullOrEmpty

      [Environment]::SetEnvironmentVariable('LVCI_SINGLE_COMPARE','1','Process')
      [Environment]::SetEnvironmentVariable('LVCI_SINGLE_COMPARE_AUTOSTOP','1','Process')
      try {
        $resp2 = Invoke-RunnerRequest -ResultsDir $resultsDir -Verb 'CompareVI' -CommandArgs $payload $resp2.ok | Should -BeFalse
        [string]$resp2.error | Should -Match 'compare_already_handled'
        $entries2 = Get-Content -LiteralPath $requestLog | ForEach-Object { $_ | ConvertFrom-Json }
        ($entries2 | Where-Object stage -eq 'failed') | Should -Not -BeNullOrEmpty
      } finally {
        [Environment]::SetEnvironmentVariable('LVCI_SINGLE_COMPARE',$null,'Process')
        [Environment]::SetEnvironmentVariable('LVCI_SINGLE_COMPARE_AUTOSTOP',$null,'Process')
      }
    }
    finally {
      $phaseDone = Invoke-RunnerRequest -ResultsDir $resultsDir -Verb 'PhaseDone' $phaseDone.ok | Should -BeTrue
      $phaseDone.result.done | Should -BeTrue

      $deadline = (Get-Date).AddSeconds(5)
      while ((Get-Date) -lt $deadline -and (Test-Path -LiteralPath $sentinel)) { Start-Sleep -Milliseconds 50 }
      (Test-Path -LiteralPath $sentinel) | Should -BeFalse

      Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
      Wait-Job -Id $job.Id -Timeout 5 | Out-Null
      Receive-Job -Id $job.Id -ErrorAction SilentlyContinue | Out-Null
      Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
    }
  }
}
