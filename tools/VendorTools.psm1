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

function Get-LabVIEWCandidateExePaths {
  param([string]$LabVIEWExePath)

  if (-not $IsWindows) { return @() }

  $candidates = New-Object System.Collections.Generic.List[string]

  if (-not [string]::IsNullOrWhiteSpace($LabVIEWExePath)) {
    $candidates.Add($LabVIEWExePath)
  }

  foreach ($envValue in @($env:LABVIEW_PATH, $env:LABVIEW_EXE_PATH)) {
    if ([string]::IsNullOrWhiteSpace($envValue)) { continue }
    foreach ($entry in ($envValue -split ';')) {
      if (-not [string]::IsNullOrWhiteSpace($entry)) {
        $candidates.Add($entry.Trim())
      }
    }
  }

  $root = Resolve-RepoRoot
  foreach ($configName in @('labview-paths.local.json','labview-paths.json')) {
    $configPath = Join-Path $root "configs/$configName"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }
    try {
      $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 4
      if ($config -and $config.PSObject.Properties['labview']) {
        $entries = $config.labview
        if ($entries -is [string]) { $candidates.Add($entries) }
        elseif ($entries -is [System.Collections.IEnumerable]) {
          foreach ($item in $entries) {
            if ($item) { $candidates.Add([string]$item) }
          }
        }
      }
    } catch {}
  }

  $programRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($rootPath in $programRoots) {
    try {
      $niRoot = Join-Path $rootPath 'National Instruments'
      if (-not (Test-Path -LiteralPath $niRoot -PathType Container)) { continue }
      $labviewDirs = Get-ChildItem -LiteralPath $niRoot -Directory -Filter 'LabVIEW*' -ErrorAction SilentlyContinue
      foreach ($dir in $labviewDirs) {
        $exe = Join-Path $dir.FullName 'LabVIEW.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
          $candidates.Add($exe)
        }
      }
    } catch {}
  }

  $resolved = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $path = (Resolve-Path -LiteralPath $candidate).Path
        if (-not $resolved.Contains($path)) {
          $resolved.Add($path)
        }
      }
    } catch {}
  }

  return $resolved.ToArray()
}

function Get-LabVIEWIniPath {
  param(
    [string]$LabVIEWExePath
  )

  foreach ($exe in (Get-LabVIEWCandidateExePaths -LabVIEWExePath $LabVIEWExePath)) {
    try {
      $rootDir = Split-Path -Parent $exe
      $iniCandidate = Join-Path $rootDir 'LabVIEW.ini'
      if (Test-Path -LiteralPath $iniCandidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $iniCandidate).Path
      }
    } catch {}
  }
  return $null
}

function Get-LabVIEWIniValue {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [string]$LabVIEWIniPath,
    [string]$LabVIEWExePath
  )

  if (-not $IsWindows) { return $null }

  if ([string]::IsNullOrWhiteSpace($LabVIEWIniPath)) {
    $LabVIEWIniPath = Get-LabVIEWIniPath -LabVIEWExePath $LabVIEWExePath
  }
  if (-not $LabVIEWIniPath) { return $null }

  try {
    foreach ($line in (Get-Content -LiteralPath $LabVIEWIniPath)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      if ($line -match '^\s*[#;]') { continue }
      $parts = $line -split '=', 2
      if ($parts.Count -ne 2) { continue }
      if ($parts[0].Trim() -ieq $Key) {
        return $parts[1].Trim()
      }
    }
  } catch {}

  return $null
}

Export-ModuleMember -Function *
