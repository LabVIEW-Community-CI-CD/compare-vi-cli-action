Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Prepare-StandingCommit helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:toolPath = Join-Path $repoRoot 'tools' 'Prepare-StandingCommit.ps1'
    $script:configPath = Join-Path $repoRoot '.agent_push_config.json'
    $script:createRepo = {
      param(
        [string]$ConfigPath,
        [string]$Title = 'Add push target contract helper',
        [int]$Number = 260
      )
      $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      git init $path | Out-Null
      Push-Location $path
      try {
        git config user.name 'Test User' | Out-Null
        git config user.email 'test@example.com' | Out-Null
        Set-Content -LiteralPath 'README.md' -Encoding ascii -Value 'seed'
        git add README.md | Out-Null
        git commit -m 'init' | Out-Null
        $current = (git rev-parse --abbrev-ref HEAD).Trim()
        if ($current -ne 'develop') {
          git checkout -b develop | Out-Null
        }
        if ($ConfigPath) {
          Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $path '.agent_push_config.json')
        }
        $priority = @{
          number = $Number
          title  = $Title
        } | ConvertTo-Json
        Set-Content -LiteralPath '.agent_priority_cache.json' -Value $priority -Encoding utf8
        git add '.agent_priority_cache.json' | Out-Null
        git commit -m 'seed priority cache' | Out-Null
      } finally {
        Pop-Location
      }
      return $path
    }
  }

  It 'creates standing branch and stages tracked edits' {
    $repo = & $script:createRepo -ConfigPath $script:configPath
    Push-Location $repo
    try {
      Add-Content -LiteralPath 'README.md' -Value "`nupdate" -Encoding utf8
    } finally {
      Pop-Location
    }

    & $script:toolPath -RepositoryRoot $repo -NoSummary
    $LASTEXITCODE | Should -Be 0

    Push-Location $repo
    try {
      $branch = (git rev-parse --abbrev-ref HEAD).Trim()
      $branch | Should -Be 'issue/260-add-push-target-contract-helper'

      $staged = git diff --cached --name-only
      $staged | Should -Contain 'README.md'
      $staged | Should -Not -Contain '.agent_priority_cache.json'
    } finally {
      Pop-Location
    }
  }

  It 'auto commits with generated message' {
    $repo = & $script:createRepo -ConfigPath $script:configPath
    Push-Location $repo
    try {
      Add-Content -LiteralPath 'README.md' -Value "`nupdate" -Encoding utf8
    } finally {
      Pop-Location
    }

    & $script:toolPath -RepositoryRoot $repo -AutoCommit
    $LASTEXITCODE | Should -Be 0

    Push-Location $repo
    try {
      $commitMessage = (git log -1 --pretty='%s').Trim()
      $commitMessage | Should -Match 'chore\(#260\):'
    } finally {
      Pop-Location
    }
  }

  It 'skips cache file and records summary' {
    $repo = & $script:createRepo -ConfigPath $script:configPath
    Push-Location $repo
    try {
      Add-Content -LiteralPath '.agent_priority_cache.json' -Value ' ' -Encoding utf8
    } finally {
      Pop-Location
    }

    & $script:toolPath -RepositoryRoot $repo
    $LASTEXITCODE | Should -Be 0

    $summaryPath = Join-Path $repo 'tests/results/_agent/commit-plan.json'
    Test-Path $summaryPath | Should -BeTrue
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $summary.autoSkipped | Should -Contain '.agent_priority_cache.json'
    $summary.staged | Should -Not -Contain '.agent_priority_cache.json'
    $summary.commitType | Should -Be 'chore'
    $summary.suggestedMessage | Should -Match 'chore\(#260\):'
    $summary.labels | Should -Contain 'standing priority update'
    $summary.commitMessageStatus.needsEdit | Should -BeFalse
    $summary.commitMessageStatus.state | Should -Be 'no-staged-files'
    $summary.tests.decision | Should -Be 'skip'
    $summary.tests.reasons | Should -Contain 'no-staged-files'
  }

  It 'flags doc-only additions as needing message review' {
    $repo = & $script:createRepo -ConfigPath $script:configPath
    Push-Location $repo
    try {
      New-Item -ItemType Directory -Force -Path 'docs' | Out-Null
      Set-Content -LiteralPath (Join-Path 'docs' 'new-doc.md') -Value '# notes' -Encoding utf8
    } finally {
      Pop-Location
    }

    & $script:toolPath -RepositoryRoot $repo
    $LASTEXITCODE | Should -Be 0

    $summaryPath = Join-Path $repo 'tests/results/_agent/commit-plan.json'
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $summary.commitType | Should -Be 'feat'
    $summary.labels | Should -Contain 'docs'
    $summary.commitMessageStatus.needsEdit | Should -BeTrue
    $summary.commitMessageStatus.reasons | Should -Contain 'doc-only-change-prefers-chore'
    $summary.tests.decision | Should -Be 'skip'
    $summary.tests.docOnly | Should -BeTrue
  }
}
