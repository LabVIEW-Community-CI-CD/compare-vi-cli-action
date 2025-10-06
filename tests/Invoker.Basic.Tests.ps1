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

    $deadline = (Get-Date).AddSeconds(10)
    do { Start-Sleep -Milliseconds 200 } while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $deadline)
    (Test-Path -LiteralPath $ready) | Should -BeTrue
    (Test-Path -LiteralPath $spawn) | Should -BeTrue

    # Ping request
    $resp = pwsh -NoLogo -NoProfile -File (Join-Path $root 'tools/RunnerInvoker/Send-RunnerCommand.ps1') -Verb 'Ping' -ResultsDir $res | ConvertFrom-Json -Depth 5
    $resp.ok | Should -BeTrue

    # Stop
    New-Item -ItemType File -Path $sent -Force | Out-Null
    Remove-Item -LiteralPath $sent -Force -ErrorAction SilentlyContinue
    $deadline2 = (Get-Date).AddSeconds(10)
    do { Start-Sleep -Milliseconds 200 } while (-not (Test-Path -LiteralPath $stopped) -and (Get-Date) -lt $deadline2)
    (Test-Path -LiteralPath $stopped) | Should -BeTrue
  }
}

