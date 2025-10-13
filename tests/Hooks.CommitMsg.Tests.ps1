Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'commit-msg hook contract' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:HookPath = Join-Path $repoRoot 'tools' 'hooks' 'commit-msg.ps1'
    Test-Path -LiteralPath $script:HookPath | Should -BeTrue
    $script:PwshPath = (Get-Command pwsh).Source
    $script:RepoRoot = $repoRoot
    $script:RunHook = {
      param([string]$Message,[switch]$SkipFile)
      $msgPath = Join-Path $TestDrive ('commit-' + [guid]::NewGuid().ToString('N') + '.txt')
      if (-not $SkipFile) {
        if ($null -eq $Message) { $Message = '' }
        Set-Content -LiteralPath $msgPath -Value $Message -Encoding utf8
      } elseif (Test-Path -LiteralPath $msgPath) {
        Remove-Item -LiteralPath $msgPath -Force
      }
      Push-Location $script:RepoRoot
      try {
        $combined = & $script:PwshPath -NoLogo -NoProfile -File $script:HookPath -CommitMsgPath $msgPath 2>&1
        $code = if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) { $LASTEXITCODE } else { 0 }
      } finally { Pop-Location }
      $text = if ($combined) { ($combined | Out-String) } else { '' }
      [pscustomobject]@{ ExitCode = $code; Output=$text; MessagePath=$msgPath }
    }
  }

  It 'passes when subject contains issue reference and is within length guard' {
    $result = & $script:RunHook -Message "ci(watcher): trim noisy logs (#123)"
    $result.ExitCode | Should -Be 0
    $result.Output.Trim() | Should -Be ''
  }

  It 'allows WIP prefix without enforcing issue reference' {
    $result = & $script:RunHook -Message "WIP: snapshot without ticket"
    $result.ExitCode | Should -Be 0
    $result.Output.Trim() | Should -Be ''
  }

  It 'fails when subject exceeds 100 characters' {
    $subject = ('ci: ' + ('a' * 99) + ' (#123)')
    $subject.Length | Should -BeGreaterThan 100
    $result = & $script:RunHook -Message $subject
    $result.ExitCode | Should -Be 1
    $result.Output | Should -Match 'subject too long'
  }

  It 'fails when issue reference is missing' {
    $result = & $script:RunHook -Message "ci: tighten watcher telemetry output"
    $result.ExitCode | Should -Be 1
    $result.Output | Should -Match 'issue reference'
  }

  It 'ignores empty or whitespace-only subjects' {
    $result = & $script:RunHook -Message "`n"
    $result.ExitCode | Should -Be 0
    $result.Output.Trim() | Should -Be ''
  }

  It 'exits successfully when commit message file is missing' {
    $result = & $script:RunHook -SkipFile
    $result.ExitCode | Should -Be 0
    $result.Output.Trim() | Should -Be ''
  }
}
