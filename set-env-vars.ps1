$ErrorActionPreference='Stop'
$vi1 = Resolve-Path -LiteralPath './VI1.vi' -ErrorAction SilentlyContinue
$vi2 = Resolve-Path -LiteralPath './VI2.vi' -ErrorAction SilentlyContinue
if (-not $vi1) { $vi1 = Resolve-Path -LiteralPath './Base.vi' -ErrorAction SilentlyContinue }
if (-not $vi2) { $vi2 = Resolve-Path -LiteralPath './Head.vi' -ErrorAction SilentlyContinue }
if (-not $vi1 -or -not $vi2) { throw 'Required VI artifacts not found: need VI1.vi & VI2.vi (preferred) or Base.vi & Head.vi (fallback).' }
$env:LV_BASE_VI = $vi1.Path
$env:LV_HEAD_VI = $vi2.Path
Write-Host "LV_BASE_VI=$env:LV_BASE_VI"
Write-Host "LV_HEAD_VI=$env:LV_HEAD_VI"
