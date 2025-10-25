Describe 'Run-VIHistory guidance helper' {
  BeforeAll {
    $script:RunVIHistoryScriptPath = Join-Path -Path (Get-Location).Path -ChildPath 'scripts/Run-VIHistory.ps1'
    $tempVi = Join-Path ([System.IO.Path]::GetTempPath()) 'missing-guidance.vi'
    . $script:RunVIHistoryScriptPath -ViPath $tempVi -StartRef 'HEAD' -MaxPairs 1 -HtmlReport:$false
  }

  It 'keeps npm alias wired for history:run -- --help' {
    Push-Location (Get-Location)
    try {
      npm run history:run -- --help 1>$null 2>$null
      $global:LASTEXITCODE | Should -Be 0
    } finally {
      Pop-Location
    }
  }

  Context 'Path handling' {
    BeforeEach {
      $global:RunHistoryTest_GitInvocations = New-Object System.Collections.ArrayList
      $global:RunHistoryTest_MockCandidates = @(
        'Alpha.vi',
        'nested/Bravo.vi',
        'charlie/Delta.vi',
        'Echo.vi',
        'Foxtrot.vi',
        'Overflow/More.vi'
      )

      function global:git {
        [void]$global:RunHistoryTest_GitInvocations.Add(@($args))

        if ($args.Count -ge 2 -and $args[1] -eq 'cat-file') {
          $global:LASTEXITCODE = 1
          return
        }

        if ($args.Count -ge 2 -and $args[1] -eq 'ls-tree') {
          $global:LASTEXITCODE = 0
          return $global:RunHistoryTest_MockCandidates
        }

        $global:LASTEXITCODE = 0
      }
    }

    AfterEach {
      Remove-Item function:git -ErrorAction SilentlyContinue
      $global:RunHistoryTest_GitInvocations = $null
      $global:RunHistoryTest_MockCandidates = $null
      $global:RunHistoryTest_WriteHostMessages = $null
    }

    It 'normalizes VI paths before checking history' {
      & $script:RunVIHistoryScriptPath -ViPath '.\examples\..\VI1.vi' -StartRef 'HEAD' -MaxPairs 1 2>&1 | Out-Null
      $catInvocation = $global:RunHistoryTest_GitInvocations | Where-Object { $_.Count -ge 2 -and $_[1] -eq 'cat-file' } | Select-Object -First 1
      $catInvocation | Should -Not -BeNullOrEmpty
      $catInvocation[3] | Should -Be 'HEAD:VI1.vi'
    }

    It 'lists candidate VI paths when the target is missing' {
      $global:RunHistoryTest_WriteHostMessages = New-Object System.Collections.Generic.List[string]

      Mock -CommandName Write-Host -MockWith {
        param([object]$Object)
        if ($null -ne $Object) {
          [void]$global:RunHistoryTest_WriteHostMessages.Add([string]$Object)
        }
      }

      & $script:RunVIHistoryScriptPath -ViPath 'Missing.vi' -StartRef 'HEAD' -MaxPairs 1 | Out-Null

      $availableLine = $global:RunHistoryTest_WriteHostMessages | Where-Object { $_ -like "Available VI paths at 'HEAD'*" } | Select-Object -First 1
      $availableLine | Should -Match "showing 5"
      $global:RunHistoryTest_WriteHostMessages | Should -Contain '  - Alpha.vi'
      $global:RunHistoryTest_WriteHostMessages | Should -Contain '  - nested/Bravo.vi'
      $global:RunHistoryTest_WriteHostMessages | Should -Contain '  - charlie/Delta.vi'
      $global:RunHistoryTest_WriteHostMessages | Should -Contain '  - Echo.vi'
      $global:RunHistoryTest_WriteHostMessages | Should -Contain '  - Foxtrot.vi'
      $global:RunHistoryTest_WriteHostMessages | Should -Contain '  ... (1 more)'
      $global:RunHistoryTest_WriteHostMessages | Where-Object { $_ -like 'Tip: git ls-tree HEAD --name-only*' } | Should -Not -BeNullOrEmpty
    }
  }

  Context 'Get-CompareHistoryGuidance' {
    It 'returns null when the error message is empty' {
      Get-CompareHistoryGuidance -ErrorMessage '' -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'outDir' | Should -BeNullOrEmpty
    }

    It 'suggests increasing MaxPairs when no commits are found' {
      $msg = 'No commits found for VI1.vi reachable from HEAD'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'outDir'
      $result | Should -Match 'Increase -MaxPairs'
      $result | Should -Match 'git log --follow -- VI1\.vi'
    }

    It 'advises verifying prior revisions when no comparison modes execute' {
      $msg = 'No comparison modes executed.'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'outDir'
      $result | Should -Match 'Ensure the VI has prior revisions'
    }

    It 'notes merge-base failures and suggests fetching commits' {
      $msg = 'git merge-base --is-ancestor failed: fatal: invalid object name'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'develop' -MaxPairs 3 -ResultsDir 'outDir'
      $result | Should -Match 'Git merge-base failed while walking history'
      $result | Should -Match 'verify VI1\.vi exists on develop'
    }

    It 'flags missing compare script' {
      $msg = 'Compare script not found: tools/Compare-VIHistory.ps1'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'outDir'
      $result | Should -Match 'compare helper script was not located'
      $result | Should -Match 'tools/priority/bootstrap.ps1'
    }

    It 'covers comparison mode misconfiguration' {
      $msg = 'No valid comparison modes resolved.'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'outDir'
      $result | Should -Match 'No comparison modes resolved'
      $result | Should -Match 'default is `default`'
    }

    It 'warns when git is unavailable' {
      $msg = 'git must be available on PATH.'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'outDir'
      $result | Should -Match 'Git is required for history capture'
    }

    It 'falls back to generic guidance for unknown errors' {
      $msg = 'Unexpected failure from Compare-VIHistory'
      $result = Get-CompareHistoryGuidance -ErrorMessage $msg -RepoRelativePath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 3 -ResultsDir 'tests/results/ref-compare/history'
      $result | Should -Match 'Inspect tests/results/ref-compare/history'
    }
  }
}


