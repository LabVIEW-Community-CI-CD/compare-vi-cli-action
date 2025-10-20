Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'After-CommitActions helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:afterPath = Join-Path $repoRoot 'tools' 'After-CommitActions.ps1'
    $script:preparePath = Join-Path $repoRoot 'tools' 'Prepare-StandingCommit.ps1'
    $script:configPath = Join-Path $repoRoot '.agent_push_config.json'

    Set-Item -Path function:New-TestRepoWithRemote -Value {
      param(
        [string]$ConfigPath,
        [int]$Issue = 260,
        [string]$Title = 'Add push target contract helper'
      )
      $bare = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.git')
      git init --bare $bare | Out-Null

      $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      git init $work | Out-Null
      Push-Location $work
      try {
        git config user.name 'Test User' | Out-Null
        git config user.email 'test@example.com' | Out-Null
        git remote add origin $bare | Out-Null
        Set-Content -LiteralPath 'README.md' -Value 'seed' -Encoding ascii
        git add README.md | Out-Null
        git commit -m 'init' | Out-Null
        git checkout -b 'issue/260-add-target-helper' | Out-Null
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $work '.agent_push_config.json')
        New-Item -ItemType Directory -Path (Join-Path $work 'tools') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'tools' 'Ensure-AgentPushTarget.ps1') -Destination (Join-Path $work 'tools' 'Ensure-AgentPushTarget.ps1')
        $priority = @{
          number = $Issue
          title  = $Title
        } | ConvertTo-Json
        Set-Content -LiteralPath '.agent_priority_cache.json' -Value $priority -Encoding utf8
        Add-Content -LiteralPath 'README.md' -Value "`nupdate" -Encoding utf8
      } finally {
        Pop-Location
      }
      return [pscustomobject]@{ Work = $work; Remote = $bare }
    }
  }

  It 'pushes branch and sets upstream with auto PR disabled' {
    $repoInfo = New-TestRepoWithRemote -ConfigPath $script:configPath
    Push-Location $repoInfo.Work
    try {
      & $script:preparePath -RepositoryRoot $repoInfo.Work -AutoCommit | Out-Null
      $LASTEXITCODE | Should -Be 0

      & $script:afterPath -RepositoryRoot $repoInfo.Work -Push -CreatePR:$false | Out-Null
      $LASTEXITCODE | Should -Be 0

      $currentBranch = git rev-parse --abbrev-ref HEAD
      $upstream = git rev-parse --abbrev-ref --symbolic-full-name 'HEAD@{u}'
      $upstream.Trim() | Should -Be ('origin/' + $currentBranch)
      $summary = Get-Content -LiteralPath (Join-Path $repoInfo.Work 'tests/results/_agent/post-commit.json') -Raw | ConvertFrom-Json
      $summary.pushExecuted | Should -BeTrue
      $summary.createPR | Should -BeFalse
    } finally {
      Pop-Location
    }
  }
}
