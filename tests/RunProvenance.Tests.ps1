Describe 'Write-RunProvenance' -Tag 'Unit' {
  BeforeAll {
    $script:orig = @{
      GITHUB_REF          = $env:GITHUB_REF
      GITHUB_REF_NAME     = $env:GITHUB_REF_NAME
      GITHUB_HEAD_REF     = $env:GITHUB_HEAD_REF
      GITHUB_BASE_REF     = $env:GITHUB_BASE_REF
      GITHUB_EVENT_NAME   = $env:GITHUB_EVENT_NAME
      GITHUB_EVENT_PATH   = $env:GITHUB_EVENT_PATH
      GITHUB_REPOSITORY   = $env:GITHUB_REPOSITORY
      GITHUB_RUN_ID       = $env:GITHUB_RUN_ID
      GITHUB_RUN_ATTEMPT  = $env:GITHUB_RUN_ATTEMPT
      GITHUB_WORKFLOW     = $env:GITHUB_WORKFLOW
      GITHUB_SHA          = $env:GITHUB_SHA
      RUNNER_NAME         = $env:RUNNER_NAME
      RUNNER_OS           = $env:RUNNER_OS
      RUNNER_ARCH         = $env:RUNNER_ARCH
      RUNNER_LABELS       = $env:RUNNER_LABELS
      RUNNER_ENVIRONMENT  = $env:RUNNER_ENVIRONMENT
      RUNNER_TRACKING_ID  = $env:RUNNER_TRACKING_ID
      GITHUB_JOB          = $env:GITHUB_JOB
      ImageOS             = $env:ImageOS
      ImageVersion        = $env:ImageVersion
    }

    function Clear-ProvenanceEnv([string]$Name) {
      Remove-Item Env:$Name -ErrorAction SilentlyContinue
      [System.Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }
  }

  BeforeEach {
    $env:RUNNER_NAME = 'test-runner'
    $env:RUNNER_OS = 'Windows'
    $env:RUNNER_ARCH = 'X64'
    $env:GITHUB_JOB = 'unit-tests'
    $env:RUNNER_ENVIRONMENT = 'self-hosted'
    $env:RUNNER_TRACKING_ID = 'tracking-test'
    $env:RUNNER_LABELS = 'self-hosted,windows,lvsuite'
    $env:ImageOS = 'windows-server-2022'
    $env:ImageVersion = '2025.10.0'
  }

  AfterAll {
    foreach ($k in $script:orig.Keys) {
      if ($null -ne $script:orig[$k]) { Set-Item -Path Env:$k -Value $script:orig[$k] } else { Remove-Item Env:$k -ErrorAction SilentlyContinue }
    }
  }

  It 'falls back to refName when headRef is empty (workflow_dispatch)' {
    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
    $env:GITHUB_REF        = 'refs/heads/feature/fallback'
    $env:GITHUB_REF_NAME   = 'feature/fallback'
    Clear-ProvenanceEnv 'GITHUB_HEAD_REF'
    Clear-ProvenanceEnv 'GITHUB_BASE_REF'
    Clear-ProvenanceEnv 'GITHUB_EVENT_PATH'
    $env:GITHUB_REPOSITORY = 'owner/repo'
    $env:GITHUB_RUN_ID = '1234'
    $env:GITHUB_RUN_ATTEMPT = '1'
    $env:GITHUB_WORKFLOW = 'orchestrated'
    $env:GITHUB_SHA = 'deadbeef'

    $outDir = Join-Path $TestDrive 'results'
    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Write-RunProvenance.ps1') -ResultsDir $outDir
    $p = Get-Content -LiteralPath (Join-Path $outDir 'provenance.json') -Raw | ConvertFrom-Json
    $p.branch | Should -Be 'feature/fallback'
    $p.refName | Should -Be 'feature/fallback'
    $p.headRef | Should -Be 'feature/fallback'
    $p.baseRef | Should -Be ''
    $p.runner.labels | Should -Contain 'self-hosted'
    $p.runner.labels | Should -Contain 'windows'
  }

  It 'uses PR event payload head/base refs and prNumber (pull_request)' {
    $env:GITHUB_EVENT_NAME = 'pull_request'
    $env:GITHUB_REF        = 'refs/pull/123/merge'
    $env:GITHUB_REF_NAME   = 'feature/from-pr'
    $evt = @{
      pull_request = @{ number = 123; head = @{ ref = 'feature/from-pr' }; base = @{ ref = 'develop' } }
    } | ConvertTo-Json
    $evtPath = Join-Path $TestDrive 'event.json'
    Set-Content -LiteralPath $evtPath -Value $evt -Encoding UTF8
    $env:GITHUB_EVENT_PATH = $evtPath
    Clear-ProvenanceEnv 'GITHUB_HEAD_REF'
    Clear-ProvenanceEnv 'GITHUB_BASE_REF'

    $outDir = Join-Path $TestDrive 'results2'
    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Write-RunProvenance.ps1') -ResultsDir $outDir
    $p = Get-Content -LiteralPath (Join-Path $outDir 'provenance.json') -Raw | ConvertFrom-Json
    $p.prNumber | Should -Be 123
    $p.headRef  | Should -Be 'feature/from-pr'
    $p.baseRef  | Should -Be 'develop'
  }

  It 'push event sets branch/refName and headRef via fallback; no prNumber' {
    $env:GITHUB_EVENT_NAME = 'push'
    $env:GITHUB_REF        = 'refs/heads/feature/push-case'
    $env:GITHUB_REF_NAME   = 'feature/push-case'
    Clear-ProvenanceEnv 'GITHUB_HEAD_REF'
    Clear-ProvenanceEnv 'GITHUB_BASE_REF'
    Clear-ProvenanceEnv 'GITHUB_EVENT_PATH'

    $outDir = Join-Path $TestDrive 'results3'
    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Write-RunProvenance.ps1') -ResultsDir $outDir
    $p = Get-Content -LiteralPath (Join-Path $outDir 'provenance.json') -Raw | ConvertFrom-Json
    $p.branch  | Should -Be 'feature/push-case'
    $p.refName | Should -Be 'feature/push-case'
    $p.headRef | Should -Be 'feature/push-case'
    ($p.PSObject.Properties.Name -contains 'prNumber') | Should -BeFalse
  }

  It 'captures strategy and include_integration via EV_* on workflow_dispatch' {
    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
    $env:GITHUB_REF        = 'refs/heads/feature/strategy-case'
    $env:GITHUB_REF_NAME   = 'feature/strategy-case'
    Clear-ProvenanceEnv 'GITHUB_HEAD_REF'
    Clear-ProvenanceEnv 'GITHUB_BASE_REF'
    $env:EV_STRATEGY = 'single'
    $env:EV_INCLUDE_INTEGRATION = 'false'

    $outDir = Join-Path $TestDrive 'results4'
    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Write-RunProvenance.ps1') -ResultsDir $outDir
    $p = Get-Content -LiteralPath (Join-Path $outDir 'provenance.json') -Raw | ConvertFrom-Json
    $p.strategy | Should -Be 'single'
    $p.include_integration | Should -Be 'false'
  }
}
