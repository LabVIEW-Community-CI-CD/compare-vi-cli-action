param(
  [Parameter(Mandatory=$true)] [string]$Command,
  [Parameter(Mandatory=$true)] [int]$ExitCode,
  [Parameter(Mandatory=$true)] [string]$Diff, # 'true'|'false'
  [Parameter(Mandatory=$true)] [string]$CliPath,
  [string]$Base,
  [string]$Head,
  [string]$OutputPath,
  [double]$DurationSeconds
)

$ErrorActionPreference = 'Stop'

# Import shared tokenization pattern
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force

function Get-BaseHeadFromCommand([string]$cmd) {
  # Tokenize respecting quotes: match quoted strings (preserving quotes) or non-space sequences
  # This pattern matches: "quoted strings" OR non-whitespace sequences
  $pattern = Get-LVCompareArgTokenPattern
  $tokens = [regex]::Matches($cmd, $pattern) | ForEach-Object { 
    $val = $_.Value
    # Remove surrounding quotes if present
    if ($val.StartsWith('"') -and $val.EndsWith('"')) {
      $val.Substring(1, $val.Length - 2)
    } else {
      $val
    }
  }
  if ($tokens.Count -ge 3) {
    return [pscustomobject]@{ Base = $tokens[1]; Head = $tokens[2] }
  }
  return $null
}

if (-not $Base -or -not $Head) {
  $parsed = Get-BaseHeadFromCommand $Command
  if ($parsed) { $Base = $parsed.Base; $Head = $parsed.Head }
}

$diffBool = $false
if ($Diff -ieq 'true') { $diffBool = $true }

$status = if ($diffBool) { 'Differences detected' } else { 'No differences' }
$color  = if ($diffBool) { '#b91c1c' } else { '#065f46' }

$exitMap = @{
  0 = 'No differences (0)'
  1 = 'Differences detected (1)'
}
$exitText = $exitMap[$ExitCode]
if (-not $exitText) { $exitText = "Unknown/Failure ($ExitCode)" }

$now = (Get-Date).ToString('u')

$css = @'
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #111827; }
h1 { font-size: 20px; }
.section { margin: 16px 0; padding: 12px; border: 1px solid #e5e7eb; border-radius: 6px; }
.kv { display: grid; grid-template-columns: 180px 1fr; row-gap: 6px; }
.key { color: #6b7280; }
.value { color: #111827; word-break: break-all; }
.status { padding: 10px; border-radius: 6px; color: white; font-weight: 600; }
.code { font-family: Consolas, monospace; background: #f3f4f6; padding: 8px; border-radius: 6px; }
'@

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>Compare VI Report</title>
<style>
$css
</style>
</head>
<body>
  <h1>Compare VI Report</h1>
  <div class="section">
    <div class="status" style="background: $color;">$status</div>
  </div>
  <div class="section">
    <div class="kv">
      <div class="key">Generated</div><div class="value">$now</div>
      <div class="key">Exit code</div><div class="value">$ExitCode ($exitText)</div>
      <div class="key">Diff</div><div class="value">$Diff</div>
  <div class="key">CLI Path</div><div class="value">$CliPath</div>
  <div class="key">Duration (s)</div><div class="value">$([string]::Format('{0:F3}', $DurationSeconds))</div>
      <div class="key">Base</div><div class="value">$Base</div>
      <div class="key">Head</div><div class="value">$Head</div>
    </div>
  </div>
  <div class="section">
    <div class="key">Command</div>
    <div class="code">$([System.Net.WebUtility]::HtmlEncode($Command))</div>
  </div>
</body>
</html>
"@

if (-not $OutputPath) {
  $outDir = Join-Path $PSScriptRoot '..' 'tests' 'results'
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  $OutputPath = Join-Path $outDir 'compare-report.html'
}

$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host ("Report written: {0}" -f (Resolve-Path $OutputPath).Path)
