$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Invoke-VIDiffSweepStrong.ps1' -Tag 'Script','IconEditor' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:strongSweepPath = Join-Path $repoRoot 'tools' 'icon-editor' 'Invoke-VIDiffSweepStrong.ps1'
    Test-Path -LiteralPath $script:strongSweepPath | Should -BeTrue
    $script:weakSweepPath = Join-Path $repoRoot 'tools' 'icon-editor' 'Invoke-VIDiffSweep.ps1'
    Test-Path -LiteralPath $script:weakSweepPath | Should -BeTrue
  }

  BeforeEach {
    [System.Environment]::SetEnvironmentVariable('ICON_EDITOR_VI_DIFF_RULES', $null, 'Process')
  }

  It 'skips pure renames without launching compares when run in DryRun mode' {
    $repoPath = Join-Path $TestDrive 'icon-editor-strong-rename'
    git init $repoPath | Out-Null
    Push-Location $repoPath
    try {
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null

      New-Item -ItemType Directory -Path 'resource/plugins' -Force | Out-Null
      Set-Content -LiteralPath 'resource/plugins/Original.vi' -Value 'initial content' -Encoding utf8
      git add . | Out-Null
      git commit -m 'initial commit' | Out-Null

      git mv 'resource/plugins/Original.vi' 'resource/plugins/Renamed.vi' | Out-Null
      git commit -m 'rename keeping content' | Out-Null

      $cachePath = Join-Path $TestDrive 'vi-diff-cache.json'
      $eventsPath = Join-Path $TestDrive 'heuristic-events.ndjson'

      $result = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -CachePath $cachePath `
        -EventsPath $eventsPath `
        -DryRun `
        -Quiet

      $result.totalCommits | Should -Be 1
      $commit = $result.commits[0]
      $commit.comparePaths.Count | Should -Be 0
      $commit.skipped.Count | Should -Be 1
      $commit.skipped[0].reason | Should -Match 'rename'
      Test-Path -LiteralPath $cachePath | Should -BeTrue
      Test-Path -LiteralPath $eventsPath | Should -BeTrue
      $commit.decision | Should -Be 'skip'
      $commit.cacheHit | Should -BeFalse
    }
    finally {
      Pop-Location
    }
  }

  It 'selects VI files with content changes for comparison decisions' {
    $repoPath = Join-Path $TestDrive 'icon-editor-strong-modify'
    git init $repoPath | Out-Null
    Push-Location $repoPath
    try {
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null

      New-Item -ItemType Directory -Path 'resource/plugins' -Force | Out-Null
      $initialContent = 'initial-version-' + ('A' * 48)
      Set-Content -LiteralPath 'resource/plugins/Sample.vi' -Value $initialContent -Encoding utf8
      git add . | Out-Null
      git commit -m 'initial commit' | Out-Null

      $expandedContent = 'updated-version-' + ('B' * 128)
      Set-Content -LiteralPath 'resource/plugins/Sample.vi' -Value $expandedContent -Encoding utf8
      git commit -am 'modify sample' | Out-Null

      $cachePath = Join-Path $TestDrive 'vi-diff-cache.json'
      $eventsPath = Join-Path $TestDrive 'heuristic-events.ndjson'

      $result = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -CachePath $cachePath `
        -EventsPath $eventsPath `
        -DryRun `
        -Quiet

      $result.totalCommits | Should -Be 1
      $commit = $result.commits[0]
      $commit.comparePaths.Count | Should -Be 1
      $commit.comparePaths[0] | Should -Match 'resource/plugins/Sample.vi'
      $commit.skipped.Count | Should -Be 0
      $commit.decision | Should -Be 'compare'
      $commit.ranCompare | Should -BeFalse
      $commit.reasons | Should -Contain 'dry-run'
      Test-Path -LiteralPath $cachePath | Should -BeTrue
      Test-Path -LiteralPath $eventsPath | Should -BeTrue
    }
    finally {
      Pop-Location
    }
  }

  It 'reuses cached skip decisions on subsequent full sweeps' {
    $repoPath = Join-Path $TestDrive 'icon-editor-cache-reuse'
    git init $repoPath | Out-Null
    Push-Location $repoPath
    try {
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null

      New-Item -ItemType Directory -Path 'resource/plugins' -Force | Out-Null
      Set-Content -LiteralPath 'resource/plugins/Original.vi' -Value 'initial content' -Encoding utf8
      git add . | Out-Null
      git commit -m 'initial commit' | Out-Null

      git mv 'resource/plugins/Original.vi' 'resource/plugins/Renamed.vi' | Out-Null
      git commit -m 'rename keeping content' | Out-Null

      $cachePath = Join-Path $TestDrive 'vi-diff-cache.json'
      $eventsPath = Join-Path $TestDrive 'heuristic-events.ndjson'

      $first = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -CachePath $cachePath `
        -EventsPath $eventsPath `
        -Quiet

      $first.totalCommits | Should -Be 1
      $first.comparedCommits | Should -Be 0
      $first.cache.writes | Should -BeGreaterThan 0
      $first.cache.hits | Should -Be 0
      $first.commits[0].decision | Should -Be 'skip'
      $first.commits[0].cacheHit | Should -BeFalse

      $second = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -CachePath $cachePath `
        -EventsPath $eventsPath `
        -Quiet

      $second.totalCommits | Should -Be 1
      $second.comparedCommits | Should -Be 0
      $second.cache.hits | Should -BeGreaterThan 0
      $second.cache.writes | Should -Be 0
      $second.commits[0].cacheHit | Should -BeTrue
      $second.commits[0].decision | Should -Be 'skip'
    }
    finally {
      Pop-Location
    }
  }

  It 'skips small size deltas via heuristics' {
    $repoPath = Join-Path $TestDrive 'icon-editor-small-delta'
    git init $repoPath | Out-Null
    Push-Location $repoPath
    try {
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null

      New-Item -ItemType Directory -Path 'resource/plugins' -Force | Out-Null
      Set-Content -LiteralPath 'resource/plugins/Tiny.vi' -Value 'AAAAA' -Encoding utf8
      git add . | Out-Null
      git commit -m 'baseline tiny' | Out-Null

      Set-Content -LiteralPath 'resource/plugins/Tiny.vi' -Value 'AAAAB' -Encoding utf8
      git commit -am 'tiny change' | Out-Null

      $rulesPath = Join-Path $TestDrive 'heuristics-small.json'
      @{
        schema = 'icon-editor/vi-diff-heuristics@v1'
        sizeDeltaBytes = 16
        prefixRules = @()
      } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $rulesPath -Encoding utf8
      [System.Environment]::SetEnvironmentVariable('ICON_EDITOR_VI_DIFF_RULES', $rulesPath, 'Process')

      $result = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -Quiet

      $result.totalCommits | Should -Be 1
      $result.comparedCommits | Should -Be 0
      $commit = $result.commits[0]
      $commit.decision | Should -Be 'skip'
      $commit.reasons | Should -Contain 'small-delta'
      $commit.comparePaths.Count | Should -Be 0
    }
    finally {
      Pop-Location
    }
  }

  It 'skips paths configured via prefix rules' {
    $repoPath = Join-Path $TestDrive 'icon-editor-prefix-rules'
    git init $repoPath | Out-Null
    Push-Location $repoPath
    try {
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null

      New-Item -ItemType Directory -Path 'resource/tutorials/examples' -Force | Out-Null
      Set-Content -LiteralPath 'resource/tutorials/examples/SkipMe.vi' -Value 'baseline' -Encoding utf8
      git add . | Out-Null
      git commit -m 'baseline tutorial' | Out-Null

      Set-Content -LiteralPath 'resource/tutorials/examples/SkipMe.vi' -Value 'changed' -Encoding utf8
      git commit -am 'update tutorial vi' | Out-Null

      $rulesPath = Join-Path $TestDrive 'heuristics-prefix.json'
      @{
        schema = 'icon-editor/vi-diff-heuristics@v1'
        sizeDeltaBytes = 0
        prefixRules = @(
          @{
            prefix = 'resource/tutorials/'
            action = 'skip'
            label  = 'tutorials'
          }
        )
      } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $rulesPath -Encoding utf8
      [System.Environment]::SetEnvironmentVariable('ICON_EDITOR_VI_DIFF_RULES', $rulesPath, 'Process')

      $result = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -Quiet

      $result.totalCommits | Should -Be 1
      $result.comparedCommits | Should -Be 0
      $commit = $result.commits[0]
      $commit.decision | Should -Be 'skip'
      $commit.reasons | Should -Contain 'prefix-skip:tutorials'
      $commit.comparePaths.Count | Should -Be 0
    }
    finally {
      Pop-Location
    }
  }

  It 'throttles compare workload when a commit exceeds the configured limit' {
    $repoPath = Join-Path $TestDrive 'icon-editor-throttle'
    git init $repoPath | Out-Null
    Push-Location $repoPath
    try {
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null

      New-Item -ItemType Directory -Path 'resource/plugins' -Force | Out-Null
      foreach ($index in 1..3) {
        $initial = "initial-$index-" + ('C' * 64)
        $path = "resource/plugins/Module$index.vi"
        Set-Content -LiteralPath $path -Value $initial -Encoding utf8
      }
      git add . | Out-Null
      git commit -m 'baseline trio' | Out-Null

      foreach ($index in 1..3) {
        $updated = "updated-$index-" + ('D' * 96)
        $path = "resource/plugins/Module$index.vi"
        Set-Content -LiteralPath $path -Value $updated -Encoding utf8
      }
      git commit -am 'modify trio' | Out-Null

      $rulesPath = Join-Path $TestDrive 'heuristics-throttle.json'
      @{
        schema = 'icon-editor/vi-diff-heuristics@v1'
        sizeDeltaBytes = 0
        maxComparePerCommit = 1
        prefixRules = @()
      } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $rulesPath -Encoding utf8
      [System.Environment]::SetEnvironmentVariable('ICON_EDITOR_VI_DIFF_RULES', $rulesPath, 'Process')

      $result = & $script:strongSweepPath `
        -RepoPath $repoPath `
        -BaseRef 'HEAD~1' `
        -HeadRef 'HEAD' `
        -DryRun `
        -Quiet

      $result.totalCommits | Should -Be 1
      $result.comparedCommits | Should -Be 0
      $commit = $result.commits[0]
      $commit.comparePaths.Count | Should -Be 1
      ($commit.skipped | Where-Object { $_.reason -match 'compare-throttle' }).Count | Should -BeGreaterThan 0
      $commit.reasons | Should -Contain 'compare-throttle:1'
      $commit.reasons | Should -Contain 'dry-run'
      $commit.ranCompare | Should -BeFalse
    }
    finally {
      Pop-Location
    }
  }
}

