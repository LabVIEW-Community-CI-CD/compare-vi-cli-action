Set-StrictMode -Version Latest

Describe 'Assert-LineEndingDeterminism.ps1' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:GuardScript = Join-Path $script:RepoRoot 'tools' 'Assert-LineEndingDeterminism.ps1'
    if (-not (Test-Path -LiteralPath $script:GuardScript -PathType Leaf)) {
      throw "Guard script not found: $script:GuardScript"
    }
  }

  It 'passes when changed files match declared EOL attributes' {
    $repoPath = Join-Path $TestDrive 'eol-pass'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'tests/results/lint') -Force | Out-Null

    Copy-Item -LiteralPath $script:GuardScript -Destination (Join-Path $toolsPath 'Assert-LineEndingDeterminism.ps1') -Force
    @'
*.md text eol=lf
'@ | Set-Content -LiteralPath (Join-Path $repoPath '.gitattributes') -Encoding ascii
    [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/good.md'), [byte[]][char[]]"# Good`n")

    Push-Location $repoPath
    try {
      git init | Out-Null
      git config core.autocrlf false
      git config user.email eol-tests@example.com
      git config user.name eol-tests
      git add .gitattributes docs/good.md tools/Assert-LineEndingDeterminism.ps1
      git commit -m 'init' | Out-Null

      [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/good.md'), [byte[]][char[]]"# Good Updated`n")
      $reportPath = Join-Path $repoPath 'tests/results/lint/line-ending-drift.json'
      & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools/Assert-LineEndingDeterminism.ps1')
      $LASTEXITCODE | Should -Be 0
      Test-Path -LiteralPath $reportPath | Should -BeTrue
    } finally {
      Pop-Location
    }
  }

  It 'fails when working tree line endings drift from declared attributes' {
    $repoPath = Join-Path $TestDrive 'eol-fail'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'tests/results/lint') -Force | Out-Null

    Copy-Item -LiteralPath $script:GuardScript -Destination (Join-Path $toolsPath 'Assert-LineEndingDeterminism.ps1') -Force
    @'
*.md text eol=lf
'@ | Set-Content -LiteralPath (Join-Path $repoPath '.gitattributes') -Encoding ascii
    [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/good.md'), [byte[]][char[]]"# Good`n")

    Push-Location $repoPath
    try {
      git init | Out-Null
      git config core.autocrlf false
      git config user.email eol-tests@example.com
      git config user.name eol-tests
      git add .gitattributes docs/good.md tools/Assert-LineEndingDeterminism.ps1
      git commit -m 'init' | Out-Null

      # Force CRLF to violate the eol=lf contract.
      [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/good.md'), [byte[]][char[]]"# Good`r`n")
      & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools/Assert-LineEndingDeterminism.ps1') 2>&1 | Out-Null
      $LASTEXITCODE | Should -Not -Be 0
    } finally {
      Pop-Location
    }
  }

  It 'skips tracked-file fallback on GitHub Actions when no files are reported as changed' {
    $repoPath = Join-Path $TestDrive 'eol-ci-no-changes'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'tests/results/lint') -Force | Out-Null

    Copy-Item -LiteralPath $script:GuardScript -Destination (Join-Path $toolsPath 'Assert-LineEndingDeterminism.ps1') -Force
    @'
*.md text eol=lf
'@ | Set-Content -LiteralPath (Join-Path $repoPath '.gitattributes') -Encoding ascii
    [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/good.md'), [byte[]][char[]]"# Good`r`n")

    Push-Location $repoPath
    $oldGitHubActions = $env:GITHUB_ACTIONS
    $oldGitHubBaseRef = $env:GITHUB_BASE_REF
    try {
      git init | Out-Null
      git config core.autocrlf false
      git config user.email eol-tests@example.com
      git config user.name eol-tests
      git add .gitattributes docs/good.md tools/Assert-LineEndingDeterminism.ps1
      git commit -m 'init' | Out-Null

      $env:GITHUB_ACTIONS = 'true'
      $env:GITHUB_BASE_REF = 'develop'
      $reportPath = Join-Path $repoPath 'tests/results/lint/line-ending-drift.json'

      & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools/Assert-LineEndingDeterminism.ps1')
      $LASTEXITCODE | Should -Be 0
      Test-Path -LiteralPath $reportPath | Should -BeTrue

      $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
      $report.changedCount | Should -Be 0
      $report.checkedCount | Should -Be 0
      $report.violationCount | Should -Be 0
    } finally {
      $env:GITHUB_ACTIONS = $oldGitHubActions
      $env:GITHUB_BASE_REF = $oldGitHubBaseRef
      Pop-Location
    }
  }

  It 'handles GitHub event payloads without pull_request metadata' {
    $repoPath = Join-Path $TestDrive 'eol-gha-no-pr-event'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'tests/results/lint') -Force | Out-Null

    Copy-Item -LiteralPath $script:GuardScript -Destination (Join-Path $toolsPath 'Assert-LineEndingDeterminism.ps1') -Force
    @'
*.md text eol=lf
'@ | Set-Content -LiteralPath (Join-Path $repoPath '.gitattributes') -Encoding ascii
    [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/good.md'), [byte[]][char[]]"# Good`n")

    Push-Location $repoPath
    $oldGitHubActions = $env:GITHUB_ACTIONS
    $oldGitHubEventPath = $env:GITHUB_EVENT_PATH
    try {
      git init | Out-Null
      git config core.autocrlf false
      git config user.email eol-tests@example.com
      git config user.name eol-tests
      git add .gitattributes docs/good.md tools/Assert-LineEndingDeterminism.ps1
      git commit -m 'init' | Out-Null

      $eventPath = Join-Path $repoPath 'event.json'
      $eventPayload = [ordered]@{
        action = 'requested'
      }
      $eventPayload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $eventPath -Encoding utf8

      $env:GITHUB_ACTIONS = 'true'
      $env:GITHUB_EVENT_PATH = $eventPath
      $reportPath = Join-Path $repoPath 'tests/results/lint/line-ending-drift.json'

      & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools/Assert-LineEndingDeterminism.ps1')
      $LASTEXITCODE | Should -Be 0
      Test-Path -LiteralPath $reportPath | Should -BeTrue

      $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
      $report.violationCount | Should -Be 0
    } finally {
      $env:GITHUB_ACTIONS = $oldGitHubActions
      $env:GITHUB_EVENT_PATH = $oldGitHubEventPath
      Pop-Location
    }
  }

  It 'uses merge-parent diff scope on synthetic merge commits in GitHub Actions' {
    $repoPath = Join-Path $TestDrive 'eol-gha-merge-scope'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'docs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoPath 'tests/results/lint') -Force | Out-Null

    Copy-Item -LiteralPath $script:GuardScript -Destination (Join-Path $toolsPath 'Assert-LineEndingDeterminism.ps1') -Force
    @'
*.md text eol=lf
'@ | Set-Content -LiteralPath (Join-Path $repoPath '.gitattributes') -Encoding ascii
    [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/a.md'), [byte[]][char[]]"# A`n")

    Push-Location $repoPath
    $oldGitHubActions = $env:GITHUB_ACTIONS
    $oldGitHubEventPath = $env:GITHUB_EVENT_PATH
    try {
      git init | Out-Null
      git branch -M main | Out-Null
      git config core.autocrlf false
      git config user.email eol-tests@example.com
      git config user.name eol-tests
      git add .gitattributes docs/a.md tools/Assert-LineEndingDeterminism.ps1
      git commit -m 'init' | Out-Null

      git checkout -b feature/one | Out-Null
      [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/a.md'), [byte[]][char[]]"# A feature`n")
      git add docs/a.md
      git commit -m 'feature change' | Out-Null
      $headSha = (& git rev-parse HEAD).Trim()

      git checkout main | Out-Null
      # Introduce a base-only mixed-ending file to verify merge-parent scoping.
      [System.IO.File]::WriteAllBytes((Join-Path $repoPath 'docs/base-only.md'), [byte[]][char[]]"# Base`r`n")
      git add docs/base-only.md
      git commit -m 'base only mixed file' | Out-Null
      $baseSha = (& git rev-parse HEAD).Trim()

      git merge --no-ff feature/one -m 'merge feature' | Out-Null

      $eventPath = Join-Path $repoPath 'event.json'
      $eventPayload = [ordered]@{
        pull_request = @{
          base = @{ sha = $baseSha }
          head = @{ sha = $headSha }
        }
      }
      $eventPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventPath -Encoding utf8

      $env:GITHUB_ACTIONS = 'true'
      $env:GITHUB_EVENT_PATH = $eventPath
      $reportPath = Join-Path $repoPath 'tests/results/lint/line-ending-drift.json'

      & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools/Assert-LineEndingDeterminism.ps1')
      $LASTEXITCODE | Should -Be 0
      Test-Path -LiteralPath $reportPath | Should -BeTrue

      $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
      $report.violationCount | Should -Be 0
      $report.changedCount | Should -Be 1
      $report.checkedCount | Should -Be 1
    } finally {
      $env:GITHUB_ACTIONS = $oldGitHubActions
      $env:GITHUB_EVENT_PATH = $oldGitHubEventPath
      Pop-Location
    }
  }
}
