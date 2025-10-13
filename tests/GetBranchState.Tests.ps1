Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'tools/Get-BranchState.ps1' {

  It 'fails outside a git repository with a helpful message' {
    Push-Location -Path $TestDrive
    $scriptRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $scriptRoot 'tools'
    $scriptPath = Join-Path $scriptPath 'Get-BranchState.ps1'
    $scriptPath = (Resolve-Path -LiteralPath $scriptPath).ProviderPath
    $pwshArgs = @('-NoLogo','-NoProfile','-File',$scriptPath)
    $output = pwsh @pwshArgs 2>&1
    $exitCode = $LASTEXITCODE
    $exitCode | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'Not inside a Git repository'
    Pop-Location
  }

  Context 'inside a repository without upstream' {
    BeforeAll {
      $repoPath = Join-Path $TestDrive 'repo-no-upstream'
      New-Item -ItemType Directory -Path $repoPath | Out-Null
      Push-Location $repoPath
      git init | Out-Null
      git config user.name 'Test User' | Out-Null
      git config user.email 'test@example.com' | Out-Null
      git config core.autocrlf false | Out-Null
      Set-Content -Path 'README.md' -Value 'hello'
      git add README.md | Out-Null
      git commit -m 'initial' | Out-Null
    }

    AfterAll {
      Pop-Location
    }

    It 'reports no upstream and a clean working tree' {
      $scriptRoot = Split-Path -Parent $PSScriptRoot
      $scriptPath = Join-Path $scriptRoot 'tools'
      $scriptPath = Join-Path $scriptPath 'Get-BranchState.ps1'
      $scriptPath = (Resolve-Path -LiteralPath $scriptPath).ProviderPath
      $pwshArgs = @('-NoLogo','-NoProfile','-File',$scriptPath,'-AsJson')
      $output = pwsh @pwshArgs 2>&1
      $LASTEXITCODE | Should -Be 0
      $json = $output -join "`n"
      $state = $json | ConvertFrom-Json
      $state.HasUpstream | Should -BeFalse
      $state.IsClean | Should -BeTrue
      $state.Ahead | Should -Be 0
      $state.Behind | Should -Be 0
    }

    It 'detects untracked files when requested' {
      $scriptRoot = Split-Path -Parent $PSScriptRoot
      $scriptPath = Join-Path $scriptRoot 'tools'
      $scriptPath = Join-Path $scriptPath 'Get-BranchState.ps1'
      $scriptPath = (Resolve-Path -LiteralPath $scriptPath).ProviderPath
      Set-Content -Path 'newfile.txt' -Value 'new'
      $pwshArgs = @('-NoLogo','-NoProfile','-File',$scriptPath,'-AsJson','-IncludeUntracked')
      $output = pwsh @pwshArgs 2>&1
      $LASTEXITCODE | Should -Be 0
      $state = ($output -join "`n") | ConvertFrom-Json
      $state.IsClean | Should -BeFalse
      $state.HasUntracked | Should -BeTrue
      $state.Untracked | Should -Contain 'newfile.txt'
      Remove-Item 'newfile.txt'
    }
  }

  Context 'inside a repository with upstream divergence' {
    BeforeAll {
      $root = Join-Path $TestDrive 'repo-upstream'
      $remoteRoot = Join-Path $TestDrive 'remote.git'
      New-Item -ItemType Directory -Path $root | Out-Null
      Push-Location $root
      git init | Out-Null
      git config user.name 'Test User' | Out-Null
      git config user.email 'test@example.com' | Out-Null
      git config core.autocrlf false | Out-Null
      Set-Content -Path 'README.md' -Value 'upstream'
      git add README.md | Out-Null
      git commit -m 'initial' | Out-Null
      git branch -M main | Out-Null
      git init --bare $remoteRoot | Out-Null
      git remote add origin $remoteRoot | Out-Null
      git push -u origin main | Out-Null

      Add-Content -Path 'README.md' -Value "`nsecond line"
      git commit -am 'ahead commit' | Out-Null
    }

    AfterAll {
      Pop-Location
    }

    It 'reports being ahead of upstream after a new commit' {
      $scriptRoot = Split-Path -Parent $PSScriptRoot
      $scriptPath = Join-Path $scriptRoot 'tools'
      $scriptPath = Join-Path $scriptPath 'Get-BranchState.ps1'
      $scriptPath = (Resolve-Path -LiteralPath $scriptPath).ProviderPath
      $pwshArgs = @('-NoLogo','-NoProfile','-File',$scriptPath,'-AsJson')
      $output = pwsh @pwshArgs 2>&1
      $LASTEXITCODE | Should -Be 0
      $state = ($output -join "`n") | ConvertFrom-Json
      $state.HasUpstream | Should -BeTrue
      $state.Ahead | Should -BeGreaterThan 0
      $state.Behind | Should -Be 0
    }
  }
}
