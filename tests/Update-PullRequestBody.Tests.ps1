<#
 Validates scripts/Update-PullRequestBody.ps1 marker replacement and append behavior.
 Uses per-test function shadowing for Invoke-RestMethod (no real network calls).
#>

BeforeAll {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
  $scriptPath = Join-Path $repoRoot 'scripts' 'Update-PullRequestBody.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing script under test: $scriptPath" }
}

Describe 'Update-PullRequestBody' {
  It 'replaces existing block between markers' {
    # Arrange temp files and env
    $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([Guid]::NewGuid()))
    try {
      $mdPath = Join-Path $tmp 'snippet.md'
      Set-Content -Path $mdPath -Value "### LabVIEW VI Compare`nStatus: ✅ No differences`n" -Encoding utf8

      $evtPath = Join-Path $tmp 'event.json'
      $payload = @{ pull_request = @{ number = 42 } } | ConvertTo-Json -Depth 4
      Set-Content -Path $evtPath -Value $payload -Encoding utf8

      $env:GITHUB_REPOSITORY = 'octo-org/hello-world'
      $env:GITHUB_TOKEN = 'test-token'
      $env:GITHUB_EVENT_PATH = $evtPath

      $existing = @(
        'Intro text',
        '<!-- vi-compare:start -->',
        'old content',
        '<!-- vi-compare:end -->',
        'Footer'
      ) -join "`n"

  $script:captured = @{ method = $null; url = $null; body = $null }
      function Invoke-RestMethod {
        param(
          [Parameter(Mandatory)] [ValidateSet('Get','PATCH','POST','PUT','DELETE')] [string]$Method,
          [Parameter(Mandatory)] [string]$Uri,
          [hashtable]$Headers,
          $Body,
          [string]$ContentType
        )
        if ($Method -eq 'Get') { return @{ body = $existing } }
        if ($Method -eq 'PATCH') {
          if ($Body) { $script:captured.body = $Body | ConvertFrom-Json }
          return @{ ok = $true }
        }
        return $null
      }

      # Act
      . $scriptPath -MarkdownPath $mdPath

      # Assert
  $script:captured.body | Should -Not -BeNullOrEmpty
  $script:captured.body.body | Should -Match '<!-- vi-compare:start -->'
  $script:captured.body.body | Should -Match 'Status: ✅ No differences'
  $script:captured.body.body | Should -Not -Match 'old content'
    }
    finally {
      Remove-Item Function:Invoke-RestMethod -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item Env:\GITHUB_REPOSITORY -ErrorAction SilentlyContinue
      Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
      Remove-Item Env:\GITHUB_EVENT_PATH -ErrorAction SilentlyContinue
    }
  }

  It 'appends a new block when markers are missing' {
    # Arrange temp files and env
    $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([Guid]::NewGuid()))
    try {
      $mdPath = Join-Path $tmp 'snippet.md'
      Set-Content -Path $mdPath -Value "### LabVIEW VI Compare`nStatus: ⚠️ Differences detected`n" -Encoding utf8

      $evtPath = Join-Path $tmp 'event.json'
      $payload = @{ pull_request = @{ number = 7 } } | ConvertTo-Json -Depth 4
      Set-Content -Path $evtPath -Value $payload -Encoding utf8

      $env:GITHUB_REPOSITORY = 'octo-org/hello-world'
      $env:GITHUB_TOKEN = 'test-token'
      $env:GITHUB_EVENT_PATH = $evtPath

      $existing = 'Hello world body'
  $script:captured = @{ body = $null }
      function Invoke-RestMethod {
        param(
          [Parameter(Mandatory)] [ValidateSet('Get','PATCH','POST','PUT','DELETE')] [string]$Method,
          [Parameter(Mandatory)] [string]$Uri,
          [hashtable]$Headers,
          $Body,
          [string]$ContentType
        )
        if ($Method -eq 'Get') { return @{ body = $existing } }
        if ($Method -eq 'PATCH') {
          if ($Body) { $script:captured.body = $Body | ConvertFrom-Json }
          return @{ ok = $true }
        }
        return $null
      }

      # Act
      . $scriptPath -MarkdownPath $mdPath

      # Assert
  $script:captured.body | Should -Not -BeNullOrEmpty
  $script:captured.body.body | Should -Match 'Hello world body'
  $script:captured.body.body | Should -Match '<!-- vi-compare:start -->'
  $script:captured.body.body | Should -Match 'Differences detected'
    }
    finally {
      Remove-Item Function:Invoke-RestMethod -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item Env:\GITHUB_REPOSITORY -ErrorAction SilentlyContinue
      Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
      Remove-Item Env:\GITHUB_EVENT_PATH -ErrorAction SilentlyContinue
    }
  }
}
