Set-StrictMode -Version Latest

Describe 'Lint-Markdown.ps1' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:LintScriptSource = Join-Path $script:RepoRoot 'tools' 'Lint-Markdown.ps1'
    if (-not (Test-Path -LiteralPath $script:LintScriptSource -PathType Leaf)) {
      throw "Lint script not found at $script:LintScriptSource"
    }
  }

  It 'handles a single changed markdown file without scalar count errors' {
    $repoPath = Join-Path $TestDrive 'single-file'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    Copy-Item -LiteralPath $script:LintScriptSource -Destination (Join-Path $toolsPath 'Lint-Markdown.ps1') -Force

    @'
function Resolve-MarkdownlintCli2Path {
  return (Join-Path $PSScriptRoot 'fake-markdownlint.ps1')
}

Export-ModuleMember -Function Resolve-MarkdownlintCli2Path
'@ | Set-Content -LiteralPath (Join-Path $toolsPath 'VendorTools.psm1') -Encoding UTF8

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
exit 0
'@ | Set-Content -LiteralPath (Join-Path $toolsPath 'fake-markdownlint.ps1') -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoPath '.markdownlint.jsonc') -Encoding UTF8 -Value '{"default":true,"MD013":false}'
    Set-Content -LiteralPath (Join-Path $repoPath '.markdownlintignore') -Encoding UTF8 -Value ''
    Set-Content -LiteralPath (Join-Path $repoPath 'README.md') -Encoding UTF8 -Value "# Seed`n"
    Set-Content -LiteralPath (Join-Path $repoPath 'single.md') -Encoding UTF8 -Value "# Single`n"

    Push-Location $repoPath
    try {
      git init | Out-Null
      git config user.email lint-tests@example.com
      git config user.name lint-tests
      git add README.md .markdownlint.jsonc .markdownlintignore tools
      git commit -m 'init' | Out-Null

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools' 'Lint-Markdown.ps1') 2>&1
      $exitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }

    $joined = @($output | ForEach-Object { [string]$_ }) -join "`n"
    $exitCode | Should -Be 0
    $joined | Should -Match 'Linting 1 Markdown file\(s\)\.'
    $joined | Should -Not -Match "property 'Count' cannot be found"
  }

  It 'suppresses temporary markdown drafts from changed-file lint selection' {
    $repoPath = Join-Path $TestDrive 'suppressed-temp'
    $toolsPath = Join-Path $repoPath 'tools'
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    Copy-Item -LiteralPath $script:LintScriptSource -Destination (Join-Path $toolsPath 'Lint-Markdown.ps1') -Force

    @'
function Resolve-MarkdownlintCli2Path {
  return (Join-Path $PSScriptRoot 'fake-markdownlint.ps1')
}

Export-ModuleMember -Function Resolve-MarkdownlintCli2Path
'@ | Set-Content -LiteralPath (Join-Path $toolsPath 'VendorTools.psm1') -Encoding UTF8

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
exit 0
'@ | Set-Content -LiteralPath (Join-Path $toolsPath 'fake-markdownlint.ps1') -Encoding UTF8

    Set-Content -LiteralPath (Join-Path $repoPath '.markdownlint.jsonc') -Encoding UTF8 -Value '{"default":true,"MD013":false}'
    Set-Content -LiteralPath (Join-Path $repoPath '.markdownlintignore') -Encoding UTF8 -Value ''
    Set-Content -LiteralPath (Join-Path $repoPath 'README.md') -Encoding UTF8 -Value "# Seed`n"
    Set-Content -LiteralPath (Join-Path $repoPath '.tmp-scratch.md') -Encoding UTF8 -Value 'draft'
    Set-Content -LiteralPath (Join-Path $repoPath 'pr-123-body.md') -Encoding UTF8 -Value 'draft'

    Push-Location $repoPath
    try {
      git init | Out-Null
      git config user.email lint-tests@example.com
      git config user.name lint-tests
      git add README.md .markdownlint.jsonc .markdownlintignore tools
      git commit -m 'init' | Out-Null

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoPath 'tools' 'Lint-Markdown.ps1') 2>&1
      $exitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }

    $joined = @($output | ForEach-Object { [string]$_ }) -join "`n"
    $exitCode | Should -Be 0
    $joined | Should -Match 'No Markdown files to lint\.'
  }
}
