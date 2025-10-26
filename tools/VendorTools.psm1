#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-ConsoleUtf8 {
  try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::UTF8
  } catch {}
}

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

function Resolve-BinPath {
  param(
    [Parameter(Mandatory)] [string]$Name
  )
  $root = Resolve-RepoRoot
  $bin = Join-Path $root 'bin'
  if ($IsWindows) {
    $exe = Join-Path $bin ("{0}.exe" -f $Name)
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
  }
  $nix = Join-Path $bin $Name
  if (Test-Path -LiteralPath $nix -PathType Leaf) { return $nix }
  return $null
}

function Resolve-ActionlintPath {
  $p = Resolve-BinPath -Name 'actionlint'
  if ($IsWindows -and $p -and (Split-Path -Leaf $p) -eq 'actionlint') {
    $alt = Join-Path (Split-Path -Parent $p) 'actionlint.exe'
    if (Test-Path -LiteralPath $alt -PathType Leaf) { return $alt }
  }
  return $p
}

function Resolve-MarkdownlintCli2Path {
  $root = Resolve-RepoRoot
  if ($IsWindows) {
    $candidates = @(
      (Join-Path $root 'node_modules/.bin/markdownlint-cli2.cmd'),
      (Join-Path $root 'node_modules/.bin/markdownlint-cli2.ps1')
    )
  } else {
    $candidates = @(Join-Path $root 'node_modules/.bin/markdownlint-cli2')
  }
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
  return $null
}

function Get-MarkdownlintCli2Version {
  $root = Resolve-RepoRoot
  $pkg = Join-Path $root 'node_modules/markdownlint-cli2/package.json'
  if (Test-Path -LiteralPath $pkg -PathType Leaf) {
    try { return ((Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version) } catch {}
  }
  $pj = Join-Path $root 'package.json'
  if (Test-Path -LiteralPath $pj -PathType Leaf) {
    try { $decl = (Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json).devDependencies.'markdownlint-cli2'; if ($decl) { return "declared $decl (not installed)" } } catch {}
  }
  return 'unavailable'
}

function Resolve-LVComparePath {
  if (-not $IsWindows) { return $null }
  $root = Resolve-RepoRoot
  $configPath = Join-Path $root 'configs/labview-paths.json'
  $config = $null
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
      $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 4
    } catch {}
  }

  $jsonCandidates = @()
  if ($config -and $config.PSObject.Properties['lvcompare']) {
    $values = $config.lvcompare
    if ($values -is [string]) { $jsonCandidates += $values }
    if ($values -is [System.Collections.IEnumerable]) { $jsonCandidates += $values }
  }

  $envCandidates = @(
    $env:LVCOMPARE_PATH,
    $env:LV_COMPARE_PATH
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $canonicalCandidates = @(
    (Join-Path $env:ProgramFiles 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe')
  )

  $allCandidates = @($jsonCandidates + $envCandidates + $canonicalCandidates) | Where-Object { $_ }
  foreach ($candidate in $allCandidates) {
    try {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
      }
    } catch {}
  }

  Write-Verbose ('VendorTools: LVCompare candidates evaluated -> {0}' -f ($allCandidates -join '; '))
  return $null
}

function Resolve-LabVIEWCliPath {
  if (-not $IsWindows) { return $null }
  $envCandidates = @(
    $env:LABVIEWCLI_PATH,
    $env:LABVIEW_CLI_PATH
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($candidate in $envCandidates) {
    try {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    } catch {}
  }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
  }
  return $null
}

Export-ModuleMember -Function *
