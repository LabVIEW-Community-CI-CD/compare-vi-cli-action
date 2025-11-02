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

function Get-VersionedConfigValues {
  param(
    $Config,
    [string]$PropertyName
  )

  $values = New-Object System.Collections.Generic.List[string]
  if (-not $Config) { return $values.ToArray() }
  $versionsProp = $Config.PSObject.Properties['versions']
  if (-not $versionsProp) { return $values.ToArray() }
  $versionsNode = $versionsProp.Value
  if (-not $versionsNode) { return $values.ToArray() }

  $versionEntries = @()
  if ($versionsNode -is [System.Collections.IDictionary]) {
    foreach ($key in $versionsNode.Keys) {
      $versionEntries += [pscustomobject]@{ Name = $key; Value = $versionsNode[$key] }
    }
  } else {
    $versionEntries = $versionsNode.PSObject.Properties
  }

  foreach ($versionEntry in $versionEntries) {
    $bitnessNode = $versionEntry.Value
    if (-not $bitnessNode) { continue }

    $bitnessEntries = @()
    if ($bitnessNode -is [System.Collections.IDictionary]) {
      foreach ($key in $bitnessNode.Keys) {
        $bitnessEntries += [pscustomobject]@{ Name = $key; Value = $bitnessNode[$key] }
      }
    } else {
      $bitnessEntries = $bitnessNode.PSObject.Properties
    }

    foreach ($bitnessEntry in $bitnessEntries) {
      $valueNode = $bitnessEntry.Value
      if (-not $valueNode) { continue }
      if ($valueNode -is [System.Collections.IDictionary]) {
        if ($valueNode.Contains($PropertyName) -and $valueNode[$PropertyName]) {
          $values.Add([string]$valueNode[$PropertyName])
        }
      } else {
        $valueProp = $valueNode.PSObject.Properties[$PropertyName]
        if ($valueProp -and $valueProp.Value) {
          $values.Add([string]$valueProp.Value)
        }
      }
    }
  }

  return $values.ToArray()
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
  if ($config -and $config.PSObject.Properties['LVComparePath'] -and $config.LVComparePath) {
    $jsonCandidates += [string]$config.LVComparePath
  }
  foreach ($value in (Get-VersionedConfigValues -Config $config -PropertyName 'LVComparePath')) {
    if ($value) { $jsonCandidates += [string]$value }
  }

  $envCandidates = @(
    $env:LVCOMPARE_PATH,
    $env:LV_COMPARE_PATH
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $canonicalCandidates = @(
    (Join-Path $env:ProgramFiles 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe')
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
  $root = Resolve-RepoRoot
  $configPath = Join-Path $root 'configs/labview-paths.json'
  $config = $null
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 4 } catch {}
  }

  if ($config) {
    $configCandidates = @()
    if ($config.PSObject.Properties['labviewcli']) {
      $entries = $config.labviewcli
      if ($entries -is [string]) { $configCandidates += $entries }
      elseif ($entries -is [System.Collections.IEnumerable]) {
        foreach ($entry in $entries) { if ($entry) { $configCandidates += [string]$entry } }
      }
    }
    if ($config.PSObject.Properties['LabVIEWCLIPath'] -and $config.LabVIEWCLIPath) {
      $configCandidates += [string]$config.LabVIEWCLIPath
    }
    foreach ($value in (Get-VersionedConfigValues -Config $config -PropertyName 'LabVIEWCLIPath')) {
      if ($value) { $configCandidates += [string]$value }
    }
    foreach ($candidate in $configCandidates) {
      try {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          return (Resolve-Path -LiteralPath $candidate).Path
        }
      } catch {}
    }
  }

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

function Get-GCliCandidateExePaths {
  param([string]$GCliExePath)

  if (-not $IsWindows) { return @() }

  $candidates = New-Object System.Collections.Generic.List[string]

  if (-not [string]::IsNullOrWhiteSpace($GCliExePath)) {
    foreach ($entry in ($GCliExePath -split ';')) {
      if (-not [string]::IsNullOrWhiteSpace($entry)) {
        $candidates.Add($entry.Trim())
      }
    }
  }

  foreach ($envName in @('GCLI_EXE_PATH','GCLI_PATH')) {
    $value = [Environment]::GetEnvironmentVariable($envName, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($envName, 'Machine') }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($envName, 'User') }
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    foreach ($entry in ($value -split ';')) {
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
      if ($config) {
        foreach ($propName in @('GCliExePath','GCliPath','gcli','gcliExePath')) {
          if ($config.PSObject.Properties[$propName] -and $config.$propName) {
            $value = $config.$propName
            if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
              foreach ($entry in $value) {
                if ($entry) { $candidates.Add([string]$entry) }
              }
            } else {
              $candidates.Add([string]$value)
            }
          }
        }
      }
      foreach ($value in (Get-VersionedConfigValues -Config $config -PropertyName 'GCliExePath')) {
        if ($value) { $candidates.Add([string]$value) }
      }
      foreach ($value in (Get-VersionedConfigValues -Config $config -PropertyName 'gcliExePath')) {
        if ($value) { $candidates.Add([string]$value) }
      }
    } catch {}
  }

  $defaultGCliPath = 'C:\Program Files\G-CLI\bin\g-cli.exe'
  $candidates.Add($defaultGCliPath)

  $resolved = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      $pathCandidate = $candidate
      if (Test-Path -LiteralPath $pathCandidate -PathType Container) {
        $pathCandidate = Join-Path $pathCandidate 'g-cli.exe'
      }
      if (Test-Path -LiteralPath $pathCandidate -PathType Leaf) {
        $resolvedPath = (Resolve-Path -LiteralPath $pathCandidate).Path
        if (-not $resolved.Contains($resolvedPath)) {
          $resolved.Add($resolvedPath)
        }
      }
    } catch {}
  }

  return $resolved.ToArray()
}

function Resolve-GCliPath {
  if (-not $IsWindows) { return $null }
  $paths = @(Get-GCliCandidateExePaths -GCliExePath $null)
  if ($paths.Count -gt 0) { return $paths[0] }
  return $null
}

function Get-LabVIEWConfig {
  $root = Resolve-RepoRoot
  foreach ($configName in @('labview-paths.local.json','labview-paths.json')) {
    $configPath = Join-Path $root "configs/$configName"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }
    try {
      $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 6
      if ($json) { return $json }
    } catch {}
  }
  return $null
}

function Get-LabVIEWConfigEntries {
  param($Config)

  $entries = New-Object System.Collections.Generic.List[object]
  if (-not $Config) { return $entries.ToArray() }

  $versionsNode = $Config.PSObject.Properties['versions']
  if ($versionsNode -and $Config.versions) {
    foreach ($versionProp in $Config.versions.PSObject.Properties) {
      $versionName = $versionProp.Name
      $versionValue = $versionProp.Value
      if (-not $versionValue) { continue }
      foreach ($bitnessProp in $versionValue.PSObject.Properties) {
        $bitnessName = $bitnessProp.Name
        $bitnessValue = $bitnessProp.Value
        if (-not $bitnessValue) { continue }
        $path = $null
        if ($bitnessValue -is [string]) {
          $path = $bitnessValue
        } elseif ($bitnessValue.PSObject.Properties['LabVIEWExePath']) {
          $path = $bitnessValue.LabVIEWExePath
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
          if (Test-Path -LiteralPath $path -PathType Leaf) {
            $resolved = (Resolve-Path -LiteralPath $path).Path
            $entries.Add([pscustomobject]@{
              Version = $versionName
              Bitness = $bitnessName
              Path    = $resolved
            }) | Out-Null
          }
        } catch {}
      }
    }
  }

  return $entries.ToArray()
}

function Find-LabVIEWVersionExePath {
  param(
    [Parameter(Mandatory)][int]$Version,
    [Parameter(Mandatory)][ValidateSet(32,64)][int]$Bitness,
    $Config = (Get-LabVIEWConfig)
  )

  $versionString = $Version.ToString()
  $bitnessString = $Bitness.ToString()

  if ($Config) {
    foreach ($entry in (Get-LabVIEWConfigEntries -Config $Config)) {
      if (($entry.Version -eq $versionString) -and ($entry.Bitness -eq $bitnessString)) {
        return $entry.Path
      }
    }
  }

  foreach ($candidate in (Get-LabVIEWCandidateExePaths)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $matchesVersion = $candidate -match ("LabVIEW\s*$versionString")
    if (-not $matchesVersion) { continue }
    $is32BitPath = $candidate -match '(?i)Program Files \(x86\)'
    $candidateBitness = if ($is32BitPath) { 32 } else { 64 }
    if ($candidateBitness -ne $Bitness) { continue }
    try {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
      }
    } catch {}
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
      if ($config -and $config.PSObject.Properties['LabVIEWExePath'] -and $config.LabVIEWExePath) {
        $candidates.Add([string]$config.LabVIEWExePath)
      }
      foreach ($value in (Get-VersionedConfigValues -Config $config -PropertyName 'LabVIEWExePath')) {
        if ($value) { $candidates.Add([string]$value) }
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
