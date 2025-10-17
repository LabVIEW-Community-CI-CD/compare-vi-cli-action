param(
  [switch]$All,
  [string]$BaseRef
)

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1') -Force
$ErrorActionPreference = 'Stop'

function Resolve-GitRoot {
  $root = (& git rev-parse --show-toplevel 2>$null).Trim()
  if (-not $root) {
    throw 'Unable to determine repository root (is git installed?).'
  }
  return $root
}

function Resolve-MergeBase {
  param([string[]]$Candidates)
  foreach ($candidate in $Candidates) {
    if (-not $candidate) { continue }
    $rawRef = (& git rev-parse --verify $candidate 2>$null)
    if (-not $rawRef) { continue }
    $ref = $rawRef.Trim()
    if (-not $ref) { continue }
    $mergeBase = (& git merge-base HEAD $ref 2>$null).Trim()
    if ($mergeBase) {
      return $mergeBase
    }
    return $ref
  }
  return $null
}

function Get-ChangedMarkdownFiles {
  param([string]$Base)
  $files = @()
  if ($Base) {
    $files += (& git diff --name-only --diff-filter=ACMRTUXB "$Base..HEAD" 2>$null)
  }
  $files += (& git diff --name-only --diff-filter=ACMRTUXB HEAD 2>$null)
  $files += (& git diff --name-only --cached --diff-filter=ACMRTUXB 2>$null)
  $files += (& git ls-files --others --exclude-standard '*.md' 2>$null)
  return ($files | Where-Object { $_ -and $_.ToLower().EndsWith('.md') } | Sort-Object -Unique)
}

function Get-AllMarkdownFiles {
  return ((& git ls-files '*.md' 2>$null) | Where-Object { $_ } | Sort-Object -Unique)
}


function Convert-GlobToRegex {
  param([string]$Pattern)

  if (-not $Pattern) { return $null }

  $normalized = $Pattern.Replace('\', '/').Trim()
  if (-not $normalized) { return $null }

  while ($normalized.StartsWith('./')) { $normalized = $normalized.Substring(2) }
  if ($normalized.StartsWith('/')) { $normalized = $normalized.Substring(1) }

  if ($normalized.EndsWith('/')) {
    $normalized = $normalized.TrimEnd('/')
    if (-not $normalized) { return $null }
    $normalized = "${normalized}/**"
  }

  $escaped = [regex]::Escape($normalized)
  $escaped = $escaped -replace '\\*\\*', '.*'
  $escaped = $escaped -replace '\\*', '[^/]*'
  $escaped = $escaped -replace '\\?', '[^/]'

  $regexPattern = "^${escaped}$"
  return [System.Text.RegularExpressions.Regex]::new($regexPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-MarkdownlintIgnorePatterns {
  param([string]$RepoRoot)

  $patterns = New-Object System.Collections.Generic.List[string]

  $ignorePath = Join-Path $RepoRoot '.markdownlintignore'
  if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $ignorePath) {
      $trimmed = $line.Trim()
      if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
      $patterns.Add($trimmed) | Out-Null
    }
  }

  $configPath = Join-Path $RepoRoot '.markdownlint.jsonc'
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
      $raw = Get-Content -LiteralPath $configPath -Raw
      $match = [System.Text.RegularExpressions.Regex]::Match($raw, '\"ignores\"\s*:\s*\[(?<values>[^\]]*)\]', [System.Text.RegularExpressions.RegexOptions]::Singleline)
      if ($match.Success) {
        foreach ($valueMatch in [System.Text.RegularExpressions.Regex]::Matches($match.Groups['values'].Value, '\"(?<item>(?:\\.|[^\"])*)\"')) {
          $item = $valueMatch.Groups['item'].Value
          if ($item) { $patterns.Add($item) | Out-Null }
        }
      }
    } catch {
      Write-Warning ("Failed to parse .markdownlint.jsonc ignores: {0}" -f $_.Exception.Message)
    }
  }

  return $patterns
}

function Get-MarkdownlintIgnoreMatchers {
  param([string]$RepoRoot)

  $patterns = Get-MarkdownlintIgnorePatterns -RepoRoot $RepoRoot
  $matchers = @()
  foreach ($pattern in $patterns) {
    $regex = Convert-GlobToRegex -Pattern $pattern
    if ($regex) { $matchers += $regex }
  }
  return $matchers
}

function Test-MarkdownlintIgnored {
  param(
    [string]$Path,
    [System.Text.RegularExpressions.Regex[]]$Matchers
  )

  if (-not $Matchers -or $Matchers.Count -eq 0) { return $false }

  $relative = $Path.Replace('\', '/')
  foreach ($matcher in $Matchers) {
    if ($matcher.IsMatch($relative)) { return $true }
  }
  return $false
}

function Invoke-Markdownlint {
  param([string[]]$Files)
  $output = @()
  $exitCode = 0
  $cli = Resolve-MarkdownlintCli2Path
  if ($cli) {
    $args = @('--config', '.markdownlint.jsonc') + $Files
    $output = & $cli @args 2>&1
    $exitCode = $LASTEXITCODE
  } else {
    $npx = Get-Command -Name 'npx' -ErrorAction SilentlyContinue
    if (-not $npx) {
      Write-Warning 'markdownlint-cli2 not found locally and npx is unavailable; skipping markdown lint.'
      return 0
    }
    $args = @('--no-install', 'markdownlint-cli2', '--config', '.markdownlint.jsonc') + $Files
    $output = & $npx.Source @args 2>&1
    $exitCode = $LASTEXITCODE
  }
  $exitCode = $LASTEXITCODE
  if ($output) {
    foreach ($entry in $output) {
      $text = [string]$entry
      $text = $text.TrimEnd()
      if ($text -ne '') {
        Write-Host $text
      }
    }
  }
  if ($exitCode -eq 0) {
    return 0
  }

  $rules = @()
  foreach ($entry in $output) {
    $line = [string]$entry
    if (-not $line) { continue }
    if ($line -match 'MD\d+') {
      $rules += $Matches[0]
    }
  }
  $nonWarningRules = ($rules | Sort-Object -Unique) | Where-Object { $_ -notin @('MD041','MD013') }
  if (-not $nonWarningRules) {
    Write-Warning 'Only MD041/MD013 violations detected; treating as a warning.'
    return 0
  }
  return [int]$exitCode
}

$repoRoot = Resolve-GitRoot
Push-Location $repoRoot
try {
  $ignoreMatchers = Get-MarkdownlintIgnoreMatchers -RepoRoot $repoRoot
  $candidateRefs = @()
  if ($BaseRef) { $candidateRefs += $BaseRef }
  if ($env:GITHUB_BASE_SHA) { $candidateRefs += $env:GITHUB_BASE_SHA }
  if ($env:GITHUB_BASE_REF) { $candidateRefs += "origin/$($env:GITHUB_BASE_REF)" }
  $candidateRefs += 'origin/develop', 'origin/main', 'HEAD~1'
  $mergeBase = $null
  if (-not $All) {
    $mergeBase = Resolve-MergeBase -Candidates $candidateRefs
  }

  $markdownFiles = @(
    if ($All) {
      Get-AllMarkdownFiles
    } else {
      Get-ChangedMarkdownFiles -Base $mergeBase
    }
  )

  if ($markdownFiles) {
    $markdownFiles = $markdownFiles | Where-Object { -not (Test-MarkdownlintIgnored -Path $_ -Matchers $ignoreMatchers) }
  }

  if (-not $markdownFiles -or $markdownFiles.Count -eq 0) {
    Write-Host 'No Markdown files to lint.'
    exit 0
  }

  # Scoped suppressions for known large/generated files until backlog is addressed
  $suppressed = @(
    'CHANGELOG.md',
    'fixture-summary.md'
  )
  $filesToLint = @($markdownFiles | Where-Object { $suppressed -notcontains $_ })

  if (-not $filesToLint -or $filesToLint.Count -eq 0) {
    Write-Host 'No Markdown files to lint.'
    exit 0
  }

  Write-Host ("Linting {0} Markdown file(s)." -f $filesToLint.Count)
  $result = Invoke-Markdownlint -Files $filesToLint
  if ($result -ne 0) {
    exit $result
  }
} finally {
  Pop-Location
}
