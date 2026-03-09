Set-StrictMode -Version Latest

Describe 'Resolve-DownloadedArtifactPath.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ResolverScript = Join-Path $script:RepoRoot 'tools' 'Resolve-DownloadedArtifactPath.ps1'
    if (-not (Test-Path -LiteralPath $script:ResolverScript -PathType Leaf)) {
      throw "Resolver script not found: $script:ResolverScript"
    }
  }

  It 'returns the absolute path for a direct child match' {
    $root = Join-Path $TestDrive 'artifacts'
    New-Item -ItemType Directory -Path $root | Out-Null
    $expectedPath = Join-Path $root 'SHA256SUMS.txt'
    Set-Content -LiteralPath $expectedPath -Value 'checksums' -Encoding ascii

    $resolvedPath = & $script:ResolverScript -SearchRoot $root -FileName 'SHA256SUMS.txt'

    $resolvedPath | Should -Be $expectedPath
  }

  It 'returns the absolute path for a nested match' {
    $root = Join-Path $TestDrive 'artifacts'
    $nested = Join-Path $root 'nested' 'release'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    $expectedPath = Join-Path $nested 'comparevi-cli-v1.2.3-linux-x64-selfcontained.tar.gz'
    Set-Content -LiteralPath $expectedPath -Value 'archive' -Encoding ascii

    $resolvedPath = & $script:ResolverScript -SearchRoot $root -FileName 'comparevi-cli-v1.2.3-linux-x64-selfcontained.tar.gz'

    $resolvedPath | Should -Be $expectedPath
  }

  It 'throws a helpful error when the target file is missing' {
    $root = Join-Path $TestDrive 'artifacts'
    $nested = Join-Path $root 'nested'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nested 'present.txt') -Value 'value' -Encoding ascii

    $thrown = { & $script:ResolverScript -SearchRoot $root -FileName 'missing.txt' } | Should -Throw -PassThru

    $thrown.Exception.Message | Should -Match "Artifact 'missing.txt' not found"
    $thrown.Exception.Message | Should -Match 'present\.txt'
  }

  It 'throws when the file name resolves to multiple matches' {
    $root = Join-Path $TestDrive 'artifacts'
    $first = Join-Path $root 'first'
    $second = Join-Path $root 'second'
    New-Item -ItemType Directory -Path $first, $second -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $first 'duplicate.txt') -Value 'first' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $second 'duplicate.txt') -Value 'second' -Encoding ascii

    $thrown = { & $script:ResolverScript -SearchRoot $root -FileName 'duplicate.txt' } | Should -Throw -PassThru

    $thrown.Exception.Message | Should -Match "Artifact 'duplicate.txt' resolved ambiguously"
    $thrown.Exception.Message | Should -Match 'first'
    $thrown.Exception.Message | Should -Match 'second'
  }
}
