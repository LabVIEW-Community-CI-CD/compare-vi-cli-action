<#
  PrePush-Checks.ps1
  - Runs actionlint across .github/workflows and fails non-zero on errors
  - Optionally performs a quick YAML round-trip check via ruamel.yaml if Python is available
  - Intended for local use and for pre-push hook wiring
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Actionlint {
  param(
    [string]$BinDir = (Join-Path $PSScriptRoot '..' 'bin'),
    [string]$Version = $env:ACTIONLINT_VERSION
  )
  if (-not $Version) { $Version = '1.7.7' }
  if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Force -Path $BinDir | Out-Null }
  $exe = Join-Path $BinDir 'actionlint'
  if (Test-Path -LiteralPath $exe) { return $exe }
  Write-Host ("Installing actionlint v{0} to {1}" -f $Version, $BinDir)
  $scriptUrl = 'https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash'
  $sh = Join-Path $BinDir 'dl-actionlint.sh'
  Invoke-WebRequest -Uri $scriptUrl -OutFile $sh -UseBasicParsing
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'bash'
  $psi.Arguments = ('-c "set -euo pipefail; bash {0} {1} {2}"' -f ($sh -replace '\\','/'), $Version, ($BinDir -replace '\\','/'))
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $null = $p.WaitForExit()
  if ($p.ExitCode -ne 0) {
    throw "Failed to install actionlint (exit=$($p.ExitCode))"
  }
  return $exe
}

function Invoke-Actionlint {
  param([string]$Exe)
  Write-Host "Running actionlint..."
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = '-color'
  $psi.WorkingDirectory = (Get-Location).Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $null = $p.WaitForExit()
  if ($out) { Write-Host $out }
  if ($err) { Write-Host $err }
  if ($p.ExitCode -ne 0) { throw "actionlint failed (exit=$($p.ExitCode))" }
}

function Invoke-YamlRoundTripCheck {
  param([string[]]$Files)
  try {
    $ok = $false
    $py = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py) { return }
    $code = @'
import sys
from ruamel.yaml import YAML
yaml = YAML(typ="rt")
for p in sys.argv[1:]:
    with open(p, 'r', encoding='utf-8') as f:
        doc = yaml.load(f)
        # dump to string to ensure roundtrip works; not writing file back
        from io import StringIO
        s = StringIO()
        yaml.dump(doc, s)
print('ok')
'@
    $tmp = New-TemporaryFile
    Set-Content -LiteralPath $tmp -Value $code -Encoding utf8
    & $py.Path $tmp @Files | Out-Null
  } catch {
    throw "YAML round-trip check failed: $_"
  } finally {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

# Main
try {
  $exe = Ensure-Actionlint
  Invoke-Actionlint -Exe $exe
  $ymls = Get-ChildItem -Path '.github/workflows' -Filter *.yml -Recurse | ForEach-Object { $_.FullName }
  if ($ymls.Count -gt 0) { Invoke-YamlRoundTripCheck -Files $ymls }
  Write-Host 'PrePush checks passed.'
  exit 0
} catch {
  Write-Error $_
  exit 2
}

