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

  $onlyX64 = $false
  if ($env:LVCI_ONLY_X64) {
    try { $onlyX64 = ($env:LVCI_ONLY_X64.Trim() -match '^(?i:1|true|yes|on)
  $onlyX64 = $false
  if ($env:LVCI_ONLY_X64) {
    try { $onlyX64 = ($env:LVCI_ONLY_X64.Trim() -match '^(?i:1|true|yes|on)$') } catch { $onlyX64 = $false }
  }
  $allowX86Fallback = $false
  if ($env:LVCI_ALLOW_X86_FALLBACK) {
    try { $allowX86Fallback = ($env:LVCI_ALLOW_X86_FALLBACK.Trim() -match '^(?i:1|true|yes|on)$') } catch { $allowX86Fallback = $false }
  }

  function __GetExeBitness([string]$Path){
    try {
      $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
      try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Seek(0x3C,[System.IO.SeekOrigin]::Begin) | Out-Null
        $e_lfanew = $br.ReadInt32()
        $fs.Seek($e_lfanew + 4,[System.IO.SeekOrigin]::Begin) | Out-Null
        $machine = $br.ReadUInt16()
        switch ($machine) { 0x014c { 'x86' }; 0x8664 { 'x64' }; default { 'other' } }
      } finally { $fs.Dispose() }
    } catch { return $null }
  }

  $candidates = @()
  $pf64 = $env:ProgramFiles
  if ($pf64) { $candidates += (Join-Path $pf64 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe') }

  $pf86 = ${env:ProgramFiles(x86)}
  if (-not $onlyX64 -or $allowX86Fallback) {
    if ($pf86) { $candidates += (Join-Path $pf86 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe') }
  }

  $checked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $fallbackX86 = $null
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
      $null = $checked.Add((Resolve-Path -LiteralPath $c).Path)
      if ($onlyX64) {
        $bit = __GetExeBitness -Path $c
        if ($bit -eq 'x64') {
          return $c
        } elseif ($allowX86Fallback -and -not $fallbackX86) {
          $fallbackX86 = $c
        }
      } else {
        return $c
      }
    }
  }

  if ($env:LABVIEW_EXE) {
    try { $lvExe = (Resolve-Path -LiteralPath $env:LABVIEW_EXE -ErrorAction Stop).Path } catch { $lvExe = $env:LABVIEW_EXE }
    if ($lvExe -and (Test-Path -LiteralPath $lvExe -PathType Leaf)) {
      $lvCandidate = Join-Path (Split-Path -Parent $lvExe) 'LVCompare.exe'
      if ($lvCandidate -and (Test-Path -LiteralPath $lvCandidate -PathType Leaf)) {
        $null = $checked.Add((Resolve-Path -LiteralPath $lvCandidate).Path)
        if ($onlyX64) {
          $bit = __GetExeBitness -Path $lvCandidate
          if ($bit -eq 'x64') {
            return $lvCandidate
          } elseif ($allowX86Fallback -and -not $fallbackX86) {
            $fallbackX86 = $lvCandidate
          }
        } else {
          return $lvCandidate
        }
      }
    }
  }

  if ($onlyX64 -and $pf64) {
    try {
      $root = Join-Path $pf64 'National Instruments'
      if (Test-Path -LiteralPath $root) {
        $found = @(Get-ChildItem -Path $root -Filter 'LVCompare.exe' -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($f in $found) {
          $resolved = (Resolve-Path -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Path
          if ($resolved -and -not $checked.Add($resolved)) { continue }
          $bit = __GetExeBitness -Path $f.FullName
          if ($bit -eq 'x64') {
            return $f.FullName
          } elseif ($allowX86Fallback -and -not $fallbackX86 -and $bit -eq 'x86') {
            $fallbackX86 = $f.FullName
          }
        }
      }
    } catch {}
  }
  if ($allowX86Fallback -and $fallbackX86) { return $fallbackX86 }
  return $null
}

Export-ModuleMember -Function *
) } catch { $onlyX64 = $false }
  }

  function __GetExeBitness([string]$Path){
    try {
      $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
      try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Seek(0x3C,[System.IO.SeekOrigin]::Begin) | Out-Null
        $e_lfanew = $br.ReadInt32()
        $fs.Seek($e_lfanew + 4,[System.IO.SeekOrigin]::Begin) | Out-Null
        $machine = $br.ReadUInt16()
        switch ($machine) { 0x014c { 'x86' }; 0x8664 { 'x64' }; default { 'other' } }
      } finally { $fs.Dispose() }
    } catch { return $null }
  }

  $candidates = @()
  $pf64 = $env:ProgramFiles
  if ($pf64) { $candidates += (Join-Path $pf64 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe') }

  if (-not $onlyX64) {
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $candidates += (Join-Path $pf86 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe') }
  }

  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
      if ($onlyX64) {
        $bit = __GetExeBitness -Path $c
        if ($bit -eq 'x64') { return $c } else { continue }
      } else {
        return $c
      }
    }
  }

  return $null
}
  $onlyX64 = $false
  if ($env:LVCI_ONLY_X64) {
    try { $onlyX64 = ($env:LVCI_ONLY_X64.Trim() -match '^(?i:1|true|yes|on)$') } catch { $onlyX64 = $false }
  }
  $allowX86Fallback = $false
  if ($env:LVCI_ALLOW_X86_FALLBACK) {
    try { $allowX86Fallback = ($env:LVCI_ALLOW_X86_FALLBACK.Trim() -match '^(?i:1|true|yes|on)$') } catch { $allowX86Fallback = $false }
  }

  function __GetExeBitness([string]$Path){
    try {
      $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
      try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Seek(0x3C,[System.IO.SeekOrigin]::Begin) | Out-Null
        $e_lfanew = $br.ReadInt32()
        $fs.Seek($e_lfanew + 4,[System.IO.SeekOrigin]::Begin) | Out-Null
        $machine = $br.ReadUInt16()
        switch ($machine) { 0x014c { 'x86' }; 0x8664 { 'x64' }; default { 'other' } }
      } finally { $fs.Dispose() }
    } catch { return $null }
  }

  $candidates = @()
  $pf64 = $env:ProgramFiles
  if ($pf64) { $candidates += (Join-Path $pf64 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe') }

  $pf86 = ${env:ProgramFiles(x86)}
  if (-not $onlyX64 -or $allowX86Fallback) {
    if ($pf86) { $candidates += (Join-Path $pf86 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe') }
  }

  $checked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $fallbackX86 = $null
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
      $null = $checked.Add((Resolve-Path -LiteralPath $c).Path)
      if ($onlyX64) {
        $bit = __GetExeBitness -Path $c
        if ($bit -eq 'x64') {
          return $c
        } elseif ($allowX86Fallback -and -not $fallbackX86) {
          $fallbackX86 = $c
        }
      } else {
        return $c
      }
    }
  }

  if ($env:LABVIEW_EXE) {
    try { $lvExe = (Resolve-Path -LiteralPath $env:LABVIEW_EXE -ErrorAction Stop).Path } catch { $lvExe = $env:LABVIEW_EXE }
    if ($lvExe -and (Test-Path -LiteralPath $lvExe -PathType Leaf)) {
      $lvCandidate = Join-Path (Split-Path -Parent $lvExe) 'LVCompare.exe'
      if ($lvCandidate -and (Test-Path -LiteralPath $lvCandidate -PathType Leaf)) {
        $null = $checked.Add((Resolve-Path -LiteralPath $lvCandidate).Path)
        if ($onlyX64) {
          $bit = __GetExeBitness -Path $lvCandidate
          if ($bit -eq 'x64') {
            return $lvCandidate
          } elseif ($allowX86Fallback -and -not $fallbackX86) {
            $fallbackX86 = $lvCandidate
          }
        } else {
          return $lvCandidate
        }
      }
    }
  }

  if ($onlyX64 -and $pf64) {
    try {
      $root = Join-Path $pf64 'National Instruments'
      if (Test-Path -LiteralPath $root) {
        $found = @(Get-ChildItem -Path $root -Filter 'LVCompare.exe' -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($f in $found) {
          $resolved = (Resolve-Path -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Path
          if ($resolved -and -not $checked.Add($resolved)) { continue }
          $bit = __GetExeBitness -Path $f.FullName
          if ($bit -eq 'x64') {
            return $f.FullName
          } elseif ($allowX86Fallback -and -not $fallbackX86 -and $bit -eq 'x86') {
            $fallbackX86 = $f.FullName
          }
        }
      }
    } catch {}
  }
  if ($allowX86Fallback -and $fallbackX86) { return $fallbackX86 }
  return $null
}

Export-ModuleMember -Function *

