${ErrorActionPreference} = 'Stop'
<#!
.SYNOPSIS
  Regenerates fixtures.manifest.json with current SHA256 & size metadata.
.DESCRIPTION
  Safely updates the manifest used by Validate-Fixtures. Requires explicit -Allow to proceed
  unless -Force supplied. Intended for controlled fixture evolution commits including
  commit message token [fixture-update].
#>
## Manual argument parsing (avoid host-specific switch binding anomalies)
$Allow=$false; $Force=$false; $DryRun=$false; $Output='fixtures.manifest.json'
for ($i=0; $i -lt $args.Length; $i++) {
  switch -Regex ($args[$i]) {
    '^-Allow$' { $Allow=$true; continue }
    '^-Force$' { $Force=$true; continue }
    '^-DryRun$' { $DryRun=$true; continue }
    '^-Output$' { if ($i+1 -lt $args.Length) { $i++; $Output=$args[$i] }; continue }
  }
}

if (-not ($Allow -or $Force)) { Write-Error 'Refusing to update manifest without -Allow (or -Force)'; exit 1 }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
$targets = @('VI1.vi','VI2.vi')
$items = @()
foreach ($t in $targets) {
  $p = Join-Path $repoRoot $t
  if (-not (Test-Path -LiteralPath $p)) { Write-Error "Fixture missing: $t"; exit 2 }
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToUpperInvariant()
  $role = if ($t -eq 'VI1.vi') { 'base' } else { 'head' }
  # Preserve existing minBytes if manifest exists
  $existingMin = 32
  if (Test-Path -LiteralPath (Join-Path $repoRoot $Output)) {
    try {
      $existing = (Get-Content -LiteralPath (Join-Path $repoRoot $Output) -Raw | ConvertFrom-Json).items | Where-Object { $_.path -eq $t }
      if ($existing -and $existing.minBytes) { $existingMin = [int]$existing.minBytes }
    } catch { }
  }
  $items += [pscustomobject]@{ path=$t; sha256=$hash; minBytes=$existingMin; role=$role }
}

$manifest = [ordered]@{
  schema = 'fixture-manifest-v1'
  generatedAt = (Get-Date).ToString('o')
  items = $items
}
$json = $manifest | ConvertTo-Json -Depth 4
$outPath = Join-Path $repoRoot $Output
if (Test-Path -LiteralPath $outPath) {
  $existing = Get-Content -LiteralPath $outPath -Raw
  if ($existing -eq $json) {
    Write-Host "Manifest unchanged: $Output"; if ($DryRun) { Write-Host 'DryRun: no write (unchanged)'; }; exit 0
  }
}
if ($DryRun) { Write-Host 'DryRun: manifest differences detected (would write new content)'; exit 0 }
Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
Write-Host "Updated manifest: $Output"
