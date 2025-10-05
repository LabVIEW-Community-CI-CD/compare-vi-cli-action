param(
  [switch]$WarnOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Get-Location).Path

# Allowed top-level directories and files (keep concise, predictable root)
$allowDirs = @(
  '.git','.github','bin','docs','module','scripts','src','tests','tools','dist'
)
$allowFiles = @(
  'action.yml','AGENTS.md','CHANGELOG.md','CONTRIBUTING.md','LICENSE','README.md','SECURITY.md',
  '.gitignore','.gitattributes','.markdownlint.json','.markdownlint.jsonc','.markdownlint-cli2.jsonc',
  '.markdownlintignore','.markdown-link-check.json','package.json','package-lock.json','tsconfig.json',
  'fixtures.manifest.json','VI1.vi','VI2.vi',
  # helper scripts allowed at root (kept minimal)
  'Invoke-PesterTests.ps1','APPLY-CI-FIXES.ps1','set-env-vars.ps1'
)

# Ignore patterns (transient/testing)
$ignoreDirs = @(
  'results','node_modules','tmp-*','tmp-*','tmp-agg','tmp-orch','tmp-rc-pester-results','tmp-fast-results','tmp-int-results',
  'tmp-pester-summary','tmp-pester-summary-all','scratch-schema-test','backup-original-vis'
)
$ignoreFiles = @(
  'testResults.xml','strict.json','override.json','final.json',
  'debug-*.log','last-run.log','full-run.log','single.log','outcome.log',
  'tmp-*.json','watch-mapping.sample.json','baseline-fixture-validation.json','current-fixture-validation.json'
)

function Match-AnyGlob([string]$name,[string[]]$globs) {
  foreach ($g in $globs) {
    $rx = [Regex]::Escape($g)
    $rx = $rx -replace '\\\*\\\\\*','.*'
    $rx = $rx -replace '\\\*','[^/\\]*'
    if ($name -match "^$rx$") { return $true }
  }
  return $false
}

$items = Get-ChildItem -LiteralPath $repoRoot -Force | Where-Object { $_.Name -ne '.' -and $_.Name -ne '..' }
$unexpected = @()
foreach ($it in $items) {
  if ($it.PSIsContainer) {
    if ($allowDirs -contains $it.Name) { continue }
    if (Match-AnyGlob $it.Name $ignoreDirs) { continue }
    $unexpected += [pscustomobject]@{ type='dir'; name=$it.Name }
  } else {
    if ($allowFiles -contains $it.Name) { continue }
    if (Match-AnyGlob $it.Name $ignoreFiles) { continue }
    $unexpected += [pscustomobject]@{ type='file'; name=$it.Name }
  }
}

if ($unexpected.Count -gt 0) {
  $lines = @('### Repo hygiene: unexpected top-level entries detected','')
  foreach ($u in $unexpected | Sort-Object type,name) { $lines += "- $($u.type): $($u.name)" }
  $lines += ''
  $lines += 'Suggested actions:'
  $lines += '- Move samples into docs/samples or tools/examples.'
  $lines += '- Delete transient artifacts (tmp-*, results/, logs) before committing.'
  $lines += '- Keep root minimal and predictable to reduce ambiguity for automation.'
  $text = $lines -join [Environment]::NewLine
  $text | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  if (-not $WarnOnly) { Write-Error "Repo hygiene check failed: unexpected entries at repo root."; exit 12 }
  else { Write-Host '::warning::Repo hygiene reported unexpected entries (warn-only mode).'}
} else {
  'Repo hygiene OK (no unexpected top-level entries).' | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
