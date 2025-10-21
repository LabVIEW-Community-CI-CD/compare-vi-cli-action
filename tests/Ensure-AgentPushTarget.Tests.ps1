Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Ensure-AgentPushTarget helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:toolPath = Join-Path $repoRoot 'tools' 'Ensure-AgentPushTarget.ps1'
    $script:configPath = Join-Path $repoRoot '.agent_push_config.json'
    Set-Item -Path function:New-TestRepo -Value {
      param(
        [string]$Branch = 'develop',
        [string]$IssueNumber = '260'
      )
      $repoPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      git init $repoPath | Out-Null
      Push-Location $repoPath
      try {
        git config user.name 'Test User' | Out-Null
        git config user.email 'test@example.com' | Out-Null
        Set-Content -LiteralPath 'README.md' -Value 'seed' -Encoding ascii
        git add README.md | Out-Null
        git commit -m 'init' | Out-Null
        git checkout -b $Branch | Out-Null
        Copy-Item -LiteralPath $script:configPath -Destination (Join-Path $repoPath '.agent_push_config.json')
        $priority = @{
          number = [int]$IssueNumber
          title  = 'Test standing issue'
        } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $repoPath '.agent_priority_cache.json') -Encoding utf8 -Value $priority
        git add '.agent_push_config.json' '.agent_priority_cache.json' | Out-Null
        git commit -m 'seed push-target contract files' | Out-Null
      } finally {
        Pop-Location
      }
      return $repoPath
    }
  }

  It 'passes for standing target when branch matches issue number and origin remote' {
    $repo = New-TestRepo -Branch 'issue/260-demo'
    Push-Location $repo
    try {
      git remote add origin https://example.invalid/repo.git | Out-Null
      git config branch.issue/260-demo.remote origin | Out-Null
      git config branch.issue/260-demo.merge refs/heads/issue/260-demo | Out-Null
      git update-ref refs/remotes/origin/issue/260-demo HEAD | Out-Null
    } finally {
      Pop-Location
    }

    $result = & $script:toolPath -RepositoryRoot $repo -Target 'standing' -NoStepSummary
    $LASTEXITCODE | Should -Be 0
    $result.status | Should -Be 'ok'
    Test-Path (Join-Path $repo 'tests/results/_agent/push-target.json') | Should -BeTrue
  }

  It 'fails when upstream remote does not match contract remote' {
    $repo = New-TestRepo -Branch 'issue/260-drift'
    Push-Location $repo
    try {
      git remote add origin https://example.invalid/repo.git | Out-Null
      git remote add upstream https://example.invalid/upstream.git | Out-Null
      git config branch.issue/260-drift.remote upstream | Out-Null
      git config branch.issue/260-drift.merge refs/heads/issue/260-drift | Out-Null
      git update-ref refs/remotes/upstream/issue/260-drift HEAD | Out-Null
    } finally {
      Pop-Location
    }

    { & $script:toolPath -RepositoryRoot $repo -Target 'standing' -NoStepSummary -NoTelemetry } | Should -Throw -ExpectedMessage "*contract remote 'origin'*"
  }

  It 'allows untracked branch when SkipTrackingCheck is specified' {
    $repo = New-TestRepo -Branch 'issue/260-initial'
    Push-Location $repo
    try {
      git remote add origin https://example.invalid/repo.git | Out-Null
      # Intentionally omit upstream configuration to simulate first push
    } finally {
      Pop-Location
    }

    $args = @(
      '-NoLogo', '-NoProfile',
      '-File', $script:toolPath,
      '-RepositoryRoot', $repo,
      '-Target', 'standing',
      '-SkipTrackingCheck',
      '-NoStepSummary',
      '-NoTelemetry'
    )
    & $script:toolPath -RepositoryRoot $repo -Target 'standing' -SkipTrackingCheck -NoStepSummary -NoTelemetry
    $LASTEXITCODE | Should -Be 0
  }

  It 'reports missing standing cache when template requires issue number' {
    $repo = New-TestRepo -Branch 'issue/260-missing'
    Remove-Item -LiteralPath (Join-Path $repo '.agent_priority_cache.json')

    { & $script:toolPath -RepositoryRoot $repo -Target 'standing' -NoStepSummary -NoTelemetry } | Should -Throw -ExpectedMessage '*priority:sync*'
  }
}
