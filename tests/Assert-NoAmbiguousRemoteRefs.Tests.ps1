Set-StrictMode -Version Latest

Describe 'Assert-NoAmbiguousRemoteRefs.ps1' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:GuardScript = Join-Path $script:RepoRoot 'tools' 'Assert-NoAmbiguousRemoteRefs.ps1'
    if (-not (Test-Path -LiteralPath $script:GuardScript -PathType Leaf)) {
      throw "Guard script not found: $script:GuardScript"
    }
  }

  AfterEach {
    Remove-Item Function:\global:git -ErrorAction SilentlyContinue
  }

  It 'falls back to HTTPS probe when SSH remote probe fails' {
    function global:git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $command = ($Args -join ' ')
      switch -Regex ($command) {
        '^ls-remote --heads --tags origin$' {
          $global:LASTEXITCODE = 128
          return @('Permission denied (publickey).')
        }
        '^remote get-url origin$' {
          $global:LASTEXITCODE = 0
          return @('git@github.com:svelderrainruiz/compare-vi-cli-action.git')
        }
        '^ls-remote --heads --tags https://github.com/svelderrainruiz/compare-vi-cli-action.git$' {
          $global:LASTEXITCODE = 0
          return @(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`trefs/heads/develop",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`trefs/tags/v0.6.0"
          )
        }
        default {
          $global:LASTEXITCODE = 0
          return @()
        }
      }
    }

    { & $script:GuardScript -Remote origin } | Should -Not -Throw
  }

  It 'reports both probe attempts when SSH and HTTPS fail' {
    function global:git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $command = ($Args -join ' ')
      switch -Regex ($command) {
        '^ls-remote --heads --tags origin$' {
          $global:LASTEXITCODE = 128
          return @('Permission denied (publickey).')
        }
        '^remote get-url origin$' {
          $global:LASTEXITCODE = 0
          return @('git@github.com:svelderrainruiz/compare-vi-cli-action.git')
        }
        '^ls-remote --heads --tags https://github.com/svelderrainruiz/compare-vi-cli-action.git$' {
          $global:LASTEXITCODE = 128
          return @('Authentication failed.')
        }
        default {
          $global:LASTEXITCODE = 0
          return @()
        }
      }
    }

    $thrown = $null
    try {
      & $script:GuardScript -Remote origin
    } catch {
      $thrown = $_
    }

    $thrown | Should -Not -BeNullOrEmpty
    $thrown.Exception.Message | Should -Match 'Attempt 1'
    $thrown.Exception.Message | Should -Match 'Attempt 2'
    $thrown.Exception.Message | Should -Match 'Mixed-shell recommendation'
  }

  It 'still fails when refs are ambiguous after HTTPS fallback' {
    function global:git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $command = ($Args -join ' ')
      switch -Regex ($command) {
        '^ls-remote --heads --tags origin$' {
          $global:LASTEXITCODE = 128
          return @('Permission denied (publickey).')
        }
        '^remote get-url origin$' {
          $global:LASTEXITCODE = 0
          return @('git@github.com:svelderrainruiz/compare-vi-cli-action.git')
        }
        '^ls-remote --heads --tags https://github.com/svelderrainruiz/compare-vi-cli-action.git$' {
          $global:LASTEXITCODE = 0
          return @(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`trefs/heads/release/v0.6.0",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`trefs/tags/release/v0.6.0"
          )
        }
        default {
          $global:LASTEXITCODE = 0
          return @()
        }
      }
    }

    { & $script:GuardScript -Remote origin } | Should -Throw -ExpectedMessage '*Ambiguous remote refs detected*'
  }
}
