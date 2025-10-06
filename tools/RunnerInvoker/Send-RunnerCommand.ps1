param(
  [string]$PipeName,
  [ValidateSet('Ping','PhaseDone','CompareVI','RenderReport')][string]$Verb = 'Ping',
  [hashtable]$Args,
  [string]$ResultsDir = 'tests/results/_invoker',
  [int]$TimeoutSeconds = 30
)
$ErrorActionPreference = 'Stop'
if (-not $PipeName) { $PipeName = "lvci.invoker.$([Environment]::GetEnvironmentVariable('GITHUB_RUN_ID')).$([Environment]::GetEnvironmentVariable('GITHUB_JOB')).$([Environment]::GetEnvironmentVariable('GITHUB_RUN_ATTEMPT'))" }
if (-not $ResultsDir) { $ResultsDir = 'tests/results/_invoker' }
$base = Join-Path $ResultsDir '_invoker'
$reqDir = Join-Path $base 'requests'
$rspDir = Join-Path $base 'responses'
foreach ($d in @($base,$reqDir,$rspDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$id = [guid]::NewGuid().ToString()
$req = [pscustomobject]@{ id=$id; verb=$Verb; args=$Args }
$reqPath = Join-Path $reqDir ("$id.json")
$rspPath = Join-Path $rspDir ("$id.json")
$req | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reqPath -Encoding UTF8

$deadline = (Get-Date).AddSeconds([math]::Max(1,$TimeoutSeconds))
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $rspPath) {
    $resp = Get-Content -LiteralPath $rspPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
    $ok = [bool]$resp.ok
    if (-not $ok) { Write-Error ([string]$resp.error) }
    $resp | ConvertTo-Json -Depth 10 -Compress | Write-Output
    return
  }
  Start-Sleep -Milliseconds 200
}
throw "invoker response timeout for verb '$Verb' id '$id'"

