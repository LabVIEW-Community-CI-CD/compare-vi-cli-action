Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  try {
    if ($global:__REPO_ROOT -and (Test-Path -LiteralPath $global:__REPO_ROOT)) { return $global:__REPO_ROOT }
  } catch {}
  $candidates = @()
  try { if ($PSScriptRoot) { $candidates += (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path } } catch {}
  try { if ($PSCommandPath) { $candidates += (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $PSCommandPath) '..')).Path } } catch {}
  try {
    $git = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $git) { $candidates += $git.Trim() }
  } catch {}
  foreach ($p in ($candidates | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($p)) {
      $probe = Join-Path $p 'scripts'
      if (Test-Path -LiteralPath $probe) { $global:__REPO_ROOT = $p; return $p }
    }
  }
  # Fallback to current location
  return (Resolve-Path '.').Path
}

