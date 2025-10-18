Describe 'Invoker (basic)' -Tag 'Unit' {
  It 'starts and stops with markers and responds to Ping' {
    $root = (Get-Location).Path
    $res  = Join-Path $TestDrive 'invoker-basic/results'
    New-Item -ItemType Directory -Path $res -Force | Out-Null
    $sent = Join-Path $TestDrive 'invoker-basic/sentinel.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $sent) -Force | Out-Null
    if (Test-Path -LiteralPath $sent) { Remove-Item -LiteralPath $sent -Force }

    # Start invoker process (hidden)
    $args = @('-NoLogo','-NoProfile','-File', (Join-Path $root 'tools/RunnerInvoker/Start-RunnerInvoker.ps1'), '-ResultsDir', $res, '-SentinelPath', $sent, '-PipeName', 'lvci.invoker.test')
    $p = Start-Process -FilePath 'pwsh' -ArgumentList $args -WindowStyle Hidden -PassThru

    $ready = Join-Path $res '_invoker/ready.json'
    $stopped = Join-Path $res '_invoker/stopped.json'
    $spawn = Join-Path $res '_invoker/console-spawns.ndjson'
    $tracker = Join-Path $res '_invoker/labview-pid.json'

    $deadline = (Get-Date).AddSeconds(10)
    do { Start-Sleep -Milliseconds 200 } while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $deadline)
    (Test-Path -LiteralPath $ready) | Should -BeTrue
    (Test-Path -LiteralPath $spawn) | Should -BeTrue
    (Test-Path -LiteralPath $tracker) | Should -BeTrue

    $readyPayload = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json -Depth 6
    $readyPayload.schema | Should -Be 'invoker-ready/v1'
    ($readyPayload.PSObject.Properties.Name -contains 'labviewPidTracker') | Should -BeTrue
    $readyPayload.labviewPidTracker.enabled | Should -BeTrue
    $readyPayload.labviewPidTracker.path | Should -Be $tracker

    # Ping request
    $modulePath = Join-Path $root 'tools/RunnerInvoker/RunnerInvoker.psm1'
    Import-Module $modulePath -Force
    $resp = Invoke-RunnerRequest -ResultsDir $res -Verb 'Ping' -CommandArgs @{} -TimeoutSeconds 5
    $resp.ok | Should -BeTrue

    # Request graceful shutdown and ensure downstream markers appear
    $doneResp = Invoke-RunnerRequest -ResultsDir $res -Verb 'PhaseDone' -TimeoutSeconds 5
    $doneResp.ok | Should -BeTrue
    $doneResp.result.done | Should -BeTrue

    $deadline2 = (Get-Date).AddSeconds(10)
    do { Start-Sleep -Milliseconds 200 } while (-not (Test-Path -LiteralPath $stopped) -and (Get-Date) -lt $deadline2)
    (Test-Path -LiteralPath $stopped) | Should -BeTrue

    $trackerPayload = Get-Content -LiteralPath $tracker -Raw | ConvertFrom-Json -Depth 6
    $trackerPayload.schema | Should -Be 'labview-pid-tracker/v1'
    ($trackerPayload.PSObject.Properties.Name -contains 'context') | Should -BeTrue
    $trackerPayload.context.stage | Should -Be 'invoker:phase-done'
    $trackerPayload.context.verb | Should -Be 'PhaseDone'
    $trackerPayload.context.done | Should -BeTrue

    $stoppedPayload = Get-Content -LiteralPath $stopped -Raw | ConvertFrom-Json -Depth 6
    $stoppedPayload.schema | Should -Be 'invoker-stopped/v1'
    ($stoppedPayload.PSObject.Properties.Name -contains 'labviewPidTracker') | Should -BeTrue
    $stoppedPayload.labviewPidTracker.enabled | Should -BeTrue
    $stoppedPayload.labviewPidTracker.path | Should -Be $tracker
    $stoppedPayload.labviewPidTracker.final.context.stage | Should -Be 'invoker:phase-done'
    $stoppedPayload.labviewPidTracker.final.context.verb | Should -Be 'PhaseDone'
    $stoppedPayload.labviewPidTracker.final.context.done | Should -BeTrue

    $deadline3 = (Get-Date).AddSeconds(5)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline3) { Start-Sleep -Milliseconds 100 }
    $p.HasExited | Should -BeTrue

    (Test-Path -LiteralPath $sent) | Should -BeFalse
  }
}

