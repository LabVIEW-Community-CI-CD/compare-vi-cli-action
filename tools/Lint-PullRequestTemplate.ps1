param(
  [string]$Path = '.github/pull_request_template.md',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) {
  Write-Host "::error::Pull request template not found: $Path"
  exit 3
}

$text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
$lines = $text -split "`r?`n"

function HasLineMatching([string]$pattern) {
  return $lines | Where-Object { $_ -match $pattern } | Select-Object -First 1
}

$missing = @()

if (-not ($lines.Count -gt 0 -and $lines[0] -match '^#\s+Pull Request\s*$')) { $missing += 'Top heading "# Pull Request"' }
if (-not (HasLineMatching '^##\s+Summary\b')) { $missing += 'Section "## Summary"' }
if (-not (HasLineMatching '^##\s+Changes\b')) { $missing += 'Section "## Changes"' }
if (-not (HasLineMatching '^##\s+Risks\s*/\s*Mitigations\b')) { $missing += 'Section "## Risks / Mitigations"' }
if (-not (HasLineMatching '^##\s+Labels\b')) { $missing += 'Section starting with "## Labels"' }
if (-not (HasLineMatching '^##\s+Validation\b')) { $missing += 'Section "## Validation"' }
if (-not (HasLineMatching '^##\s+Links\b')) { $missing += 'Section "## Links"' }
if (-not (HasLineMatching '- \[ \] .*docs/BRANCH_RULES\.md')) { $missing += 'Checklist item to verify required checks per docs/BRANCH_RULES.md' }
if (-not ($text -match 'docs/BRANCH_RULES\.md')) { $missing += 'Reference to docs/BRANCH_RULES.md' }

if ($missing.Count -gt 0) {
  $msg = "Pull request template linter: missing items:`n - " + ($missing -join "`n - ")
  Write-Host "::error::$msg"
  exit 2
}

if (-not $Quiet) { Write-Host 'Pull request template linter: OK' }
exit 0

