Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Save-WorkInProgress helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:toolPath = Join-Path $script:repoRoot 'tools' 'Save-WorkInProgress.ps1'
    Set-Item -Path function:New-WipRepo -Value {
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

  It 'creates snapshot for dirty working tree' {
    $repo = New-WipRepo
    Push-Location $repo
    try {
      Add-Content -LiteralPath 'README.md' -Value "`nchange" -Encoding utf8
      Set-Content -LiteralPath 'notes.txt' -Value 'draft' -Encoding utf8

      & $script:toolPath -RepositoryRoot $repo -Name 'unit-test'
      $LASTEXITCODE | Should -Be 0

      $wipDir = Join-Path $repo 'tests/results/_agent/wip'
      Test-Path $wipDir | Should -BeTrue
      $snapshot = Get-ChildItem -LiteralPath $wipDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      $snapshot | Should -Not -BeNullOrEmpty

      $patchPath = Join-Path $snapshot.FullName 'tracked.patch'
      Test-Path $patchPath | Should -BeTrue
      (Get-Content -LiteralPath $patchPath -Raw) | Should -Match 'change'

      $metadata = Get-Content -LiteralPath (Join-Path $snapshot.FullName 'snapshot.json') -Raw | ConvertFrom-Json
      $metadata.schema | Should -Be 'wip-snapshot/v1'
      ($metadata.entries | Where-Object { $_.Path -eq 'notes.txt' -and $_.Kind -eq 'untracked' }).Count | Should -Be 1

      $untrackedCopy = Join-Path $snapshot.FullName 'untracked/notes.txt'
      Test-Path $untrackedCopy | Should -BeTrue
      (Get-Content -LiteralPath $untrackedCopy -Raw).Trim() | Should -Be 'draft'
    } finally {
      Pop-Location
    }
  }

  It 'exits gracefully when working tree is clean' {
    $repo = New-WipRepo
    Push-Location $repo
    try {
      & $script:toolPath -RepositoryRoot $repo
      $LASTEXITCODE | Should -Be 0

      $wipDir = Join-Path $repo 'tests/results/_agent/wip'
      Test-Path $wipDir | Should -BeFalse
    } finally {
      Pop-Location
    }
  }
}
