Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Post-IssueComment.ps1' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'Post-IssueComment.ps1'
  }

  BeforeEach {
    $script:ghShimPath = Join-Path $TestDrive 'gh.ps1'
    $script:capturePath = Join-Path $TestDrive 'gh-capture.json'

    @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
)

$bodyFileIndex = [Array]::IndexOf($RemainingArgs, '--body-file')
$bodyPath = if ($bodyFileIndex -ge 0 -and ($bodyFileIndex + 1) -lt $RemainingArgs.Count) {
  $RemainingArgs[$bodyFileIndex + 1]
} else {
  $null
}

$payload = [pscustomobject]@{
  args        = @($RemainingArgs)
  bodyPath    = $bodyPath
  bodyContent = if ($bodyPath) { Get-Content -LiteralPath $bodyPath -Raw } else { $null }
}

$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:GH_CAPTURE_PATH -Encoding utf8
'@ | Set-Content -LiteralPath $script:ghShimPath -Encoding utf8

    Set-Alias -Name gh -Value $script:ghShimPath -Scope Global
    $env:GH_CAPTURE_PATH = $script:capturePath
  }

  AfterEach {
    Remove-Item Alias:gh -ErrorAction SilentlyContinue
    Remove-Item Env:GH_CAPTURE_PATH -ErrorAction SilentlyContinue
  }

  It 'uses --body-file when an explicit body file is supplied' {
    $bodyPath = Join-Path $TestDrive 'comment.md'
    $bodyText = "Comment from file`n"
    [System.IO.File]::WriteAllText($bodyPath, $bodyText)

    & $scriptPath -Issue 1396 -BodyFile $bodyPath -SkipBudgetHook -Quiet

    $capture = Get-Content -LiteralPath $script:capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $capture.args[0] | Should -Be 'issue'
    $capture.args[1] | Should -Be 'comment'
    $capture.args[2] | Should -Be '1396'
    $capture.args | Should -Contain '--body-file'
    [string]::IsNullOrWhiteSpace($capture.bodyPath) | Should -BeFalse
    $capture.bodyContent.TrimEnd("`r", "`n") | Should -BeExactly $bodyText.TrimEnd("`r", "`n")
  }

  It 'routes inline body text through a temporary body file' {
    $bodyText = @'
Continuity line
`upstream/develop...HEAD`
'@.TrimEnd("`r", "`n")

    & $scriptPath -Issue 1396 -Body $bodyText -SkipBudgetHook -Quiet

    $capture = Get-Content -LiteralPath $script:capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $capture.args | Should -Contain '--body-file'
    $capture.args | Should -Not -Contain $bodyText
    [string]::IsNullOrWhiteSpace($capture.bodyPath) | Should -BeFalse
    $capture.bodyContent.TrimEnd("`r", "`n") | Should -BeExactly $bodyText
  }

  It 'preserves edit-last mode while still using body-file transport' {
    $bodyPath = Join-Path $TestDrive 'edit-last.md'
    Set-Content -LiteralPath $bodyPath -Value 'Edit last comment' -Encoding utf8

    & $scriptPath -Issue 1396 -BodyFile $bodyPath -EditLast -SkipBudgetHook -Quiet

    $capture = Get-Content -LiteralPath $script:capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $capture.args | Should -Contain '--edit-last'
    $capture.args | Should -Contain '--body-file'
  }

  It 'appends the budget hook when a stub markdown hook file is supplied' {
    $bodyPath = Join-Path $TestDrive 'comment.md'
    $hookPath = Join-Path $TestDrive 'hook.md'
    Set-Content -LiteralPath $bodyPath -Value 'Body before hook' -Encoding utf8
    Set-Content -LiteralPath $hookPath -Value @'
<!-- priority:github-comment-budget-hook:start -->
_Budget hook_: blended lower bound `$42.500000`.
<!-- priority:github-comment-budget-hook:end -->
'@ -Encoding utf8

    & $scriptPath -Issue 1396 -BodyFile $bodyPath -BudgetHookMarkdownFile $hookPath -Quiet

    $capture = Get-Content -LiteralPath $script:capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $capture.bodyContent | Should -Match '<!-- priority:github-comment-budget-hook:start -->'
    $capture.bodyContent | Should -Match 'Body before hook'
    $capture.bodyContent | Should -Match 'blended lower bound'
  }
}
