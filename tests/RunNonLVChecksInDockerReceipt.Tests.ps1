#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Docker review-loop receipt git metadata' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunNonLVChecksScriptPath = Join-Path $repoRoot 'tools' 'Run-NonLVChecksInDocker.ps1'

    if (-not (Test-Path -LiteralPath $script:RunNonLVChecksScriptPath -PathType Leaf)) {
      throw "Run-NonLVChecksInDocker.ps1 not found at $script:RunNonLVChecksScriptPath"
    }

    function script:Get-ScriptFunctionDefinition {
      param(
        [string]$ScriptPath,
        [string]$FunctionName
      )

      $tokens = $null
      $parseErrors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
      if ($parseErrors.Count -gt 0) {
        throw ("Failed to parse {0}: {1}" -f $ScriptPath, ($parseErrors | ForEach-Object { $_.Message } | Join-String -Separator '; '))
      }

      $functionAst = $ast.Find(
        {
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $FunctionName
        },
        $true
      )
      if ($null -eq $functionAst) {
        throw ("Function {0} not found in {1}" -f $FunctionName, $ScriptPath)
      }

      return $functionAst.Extent.Text
    }

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Invoke-GitReviewLoopCommand')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:RunNonLVChecksScriptPath -FunctionName 'Get-GitReviewLoopMetadata')
  }

  It 'resolves git metadata for the current worktree even when git workspace env is poisoned' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $expectedHead = (& git -C $repoRoot rev-parse HEAD).Trim()
    $expectedBranch = (& git -C $repoRoot branch --show-current).Trim()
    $expectedMergeBase = (& git -C $repoRoot merge-base HEAD upstream/develop 2>$null | Select-Object -First 1)
    if ($null -ne $expectedMergeBase) {
      $expectedMergeBase = [string]$expectedMergeBase
      $expectedMergeBase = $expectedMergeBase.Trim()
    }

    $savedGitDir = [Environment]::GetEnvironmentVariable('GIT_DIR', 'Process')
    $savedGitWorkTree = [Environment]::GetEnvironmentVariable('GIT_WORK_TREE', 'Process')
    try {
      [Environment]::SetEnvironmentVariable('GIT_DIR', 'C:\nonexistent\git-dir', 'Process')
      [Environment]::SetEnvironmentVariable('GIT_WORK_TREE', 'C:\nonexistent\work-tree', 'Process')

      $metadata = Get-GitReviewLoopMetadata -RepoRoot $repoRoot

      $metadata.headSha | Should -Be $expectedHead
      $metadata.branch | Should -Be $expectedBranch
      $metadata.upstreamDevelopMergeBase | Should -Be $expectedMergeBase
      $metadata.dirtyTracked | Should -BeOfType ([bool])
    } finally {
      [Environment]::SetEnvironmentVariable('GIT_DIR', $savedGitDir, 'Process')
      [Environment]::SetEnvironmentVariable('GIT_WORK_TREE', $savedGitWorkTree, 'Process')
    }
  }
}
