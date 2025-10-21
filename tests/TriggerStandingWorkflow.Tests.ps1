Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Trigger-StandingWorkflow helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:toolPath = Join-Path $script:repoRoot 'tools' 'Trigger-StandingWorkflow.ps1'
    Set-Item -Path function:New-StandingRepo -Value {
      $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      git init $path | Out-Null
      Push-Location $path
      try {
        git config user.name 'Test User' | Out-Null
        git config user.email 'test@example.com' | Out-Null
        Set-Content -LiteralPath 'README.md' -Value 'seed' -Encoding ascii
        git add README.md | Out-Null
        git commit -m 'init' | Out-Null
      } finally {
        Pop-Location
      }
      return $path
    }
  }

  It 'identifies clean repository as already aligned' {
    $repo = New-StandingRepo
    Push-Location $repo
    try {
      & $script:toolPath -RepositoryRoot $repo -PlanOnly | Out-Null
      $LASTEXITCODE | Should -Be 0

      $summaryPath = Join-Path $repo 'tests/results/_agent/standing-workflow.json'
      Test-Path $summaryPath | Should -BeTrue
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
      $summary.summary.shouldRun | Should -BeFalse
    } finally {
      Pop-Location
    }
  }

  It 'flags dirty working tree as needing workflow' {
    $repo = New-StandingRepo
    Push-Location $repo
    try {
      Add-Content -LiteralPath 'README.md' -Value "`nupdate" -Encoding utf8

      & $script:toolPath -RepositoryRoot $repo -PlanOnly | Out-Null
      $LASTEXITCODE | Should -Be 0

      $summary = Get-Content -LiteralPath (Join-Path $repo 'tests/results/_agent/standing-workflow.json') -Raw | ConvertFrom-Json
      $summary.summary.shouldRun | Should -BeTrue
      $summary.reasons | Should -Contain 'working-tree-dirty'
    } finally {
      Pop-Location
    }
  }
}
