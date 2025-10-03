# Helper to ensure fixture VI files exist and are pristine enough for watcher tests
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$root = (Resolve-Path '.').ProviderPath
$fixtures = @('VI1.vi','VI2.vi')
$baselineFile = Join-Path $root '.watcher-fixture-baseline.json'
function Get-FixtureHash($path){
  if(-not (Test-Path -LiteralPath $path)){ return $null }
  try { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash } catch { $null }
}

# Establish or load baseline metadata
if(Test-Path -LiteralPath $baselineFile){
  try { $baselineRaw = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json } catch { $baselineRaw=$null }
  if($baselineRaw){
    $baseline = @{}
    foreach($prop in $baselineRaw.PSObject.Properties){ $baseline[$prop.Name] = $prop.Value }
  } else { $baseline = @{} }
} else { $baseline = @{} }

$changed=$false
foreach($f in $fixtures){
  $p = Join-Path $root $f
  if(-not (Test-Path -LiteralPath $p)){
    Write-Host "[watcher-prereq] Restoring missing $f from git" -ForegroundColor Yellow
    try { git checkout -- $f 2>$null } catch { }
  }
  if(-not (Test-Path -LiteralPath $p)){
    throw "Fixture $f still missing; cannot proceed"
  }
  $len = (Get-Item -LiteralPath $p).Length
  $hash = Get-FixtureHash $p
  if(-not $baseline.Contains($f)){
    $baseline[$f] = [ordered]@{ length=$len; sha256=$hash }
    $changed=$true
  } else {
  $b = $baseline[$f]
  if($b.length -ne $len -or $b.sha256 -ne $hash){
      Write-Host "[watcher-prereq] Detected drift for $f (baseline length=$($b.length) current=$len) restoring" -ForegroundColor Yellow
      try { git checkout -- $f 2>$null } catch { }
      if(-not (Test-Path -LiteralPath $p)){ throw "Unable to restore drifted fixture $f" }
      $len = (Get-Item -LiteralPath $p).Length
      $hash = Get-FixtureHash $p
      $baseline[$f] = [ordered]@{ length=$len; sha256=$hash }
      $changed=$true
    }
  }
}
if($changed){
  $baseline | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $baselineFile -Encoding UTF8
  Write-Host "[watcher-prereq] Baseline updated" -ForegroundColor DarkCyan
}

# Mark fixtures read-only to reduce accidental mutation in-place
foreach($f in $fixtures){
  $p = Join-Path $root $f
  try { (Get-Item -LiteralPath $p).IsReadOnly = $true } catch {}
}
