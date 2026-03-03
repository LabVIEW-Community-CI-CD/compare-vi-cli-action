Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IconEditorPathPrefixes = @(
  '.github/actions/apply-vipc/',
  'docs/icon_editor_package.md',
  'fixtures/icon-editor-history/',
  'tests/fixtures/icon-editor/',
  'tools/icon-editor/',
  'vendor/icon-editor/'
)

function Normalize-ChangedPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }
  return ($Path.Trim() -replace '\\', '/').ToLowerInvariant()
}

function Get-PrePushChangedPaths {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $paths = New-Object System.Collections.Generic.List[string]

  $upstreamResult = & git -C $RepoRoot rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
  if ($LASTEXITCODE -eq 0 -and $upstreamResult) {
    $upstream = ($upstreamResult | Select-Object -First 1).Trim()
    if ($upstream) {
      $rangePaths = & git -C $RepoRoot diff --name-only --diff-filter=ACMRTUXB "$upstream...HEAD" 2>$null
      if ($LASTEXITCODE -eq 0 -and $rangePaths) {
        foreach ($candidate in $rangePaths) {
          $normalized = Normalize-ChangedPath -Path $candidate
          if ($normalized) { $paths.Add($normalized) }
        }
      }
    }
  }

  $statusLines = & git -C $RepoRoot status --porcelain 2>$null
  if ($LASTEXITCODE -eq 0 -and $statusLines) {
    foreach ($line in $statusLines) {
      $text = "$line"
      if ($text.Length -lt 4) { continue }
      $pathPart = $text.Substring(3).Trim()
      if ($pathPart -match ' -> ') {
        $pathPart = ($pathPart -split ' -> ')[-1]
      }
      $normalized = Normalize-ChangedPath -Path $pathPart
      if ($normalized) { $paths.Add($normalized) }
    }
  }

  $deduped = $paths | Sort-Object -Unique
  return @($deduped)
}

function Test-IconEditorFixtureCheckRequired {
  [CmdletBinding()]
  param(
    [string[]]$ChangedPaths = @(),
    [switch]$Force
  )

  if ($Force) { return $true }
  foreach ($path in $ChangedPaths) {
    $normalized = Normalize-ChangedPath -Path $path
    if (-not $normalized) { continue }
    foreach ($prefix in $script:IconEditorPathPrefixes) {
      if ($normalized.StartsWith($prefix)) {
        return $true
      }
    }
  }
  return $false
}

Export-ModuleMember -Function Get-PrePushChangedPaths, Test-IconEditorFixtureCheckRequired

