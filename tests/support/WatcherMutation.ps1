<#
.SYNOPSIS
  Atomic file mutation utilities for watcher tests.
.DESCRIPTION
  Provides two-phase atomic file swap utilities to support FileSystemWatcher
  fixture tests. Enables deterministic file growth and atomic replacement
  with transient I/O error retry logic.
#>

function New-GrownCopy {
  <#
  .SYNOPSIS
    Copies source file and grows it by appending extra bytes.
  .PARAMETER Source
    Path to source file.
  .PARAMETER ExtraBytes
    Number of bytes to append (using deterministic 'A' pattern).
  .PARAMETER Destination
    Optional destination path. If omitted, creates temp file.
  .OUTPUTS
    PSCustomObject with Path and FinalLength properties.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Source,
    [Parameter(Mandatory)]
    [int]$ExtraBytes,
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Source file not found: $Source"
  }

  if ($ExtraBytes -lt 0) {
    throw "ExtraBytes must be non-negative"
  }

  $srcInfo = Get-Item -LiteralPath $Source
  $targetPath = if ($Destination) { $Destination } else {
    Join-Path ([IO.Path]::GetTempPath()) ("grown-copy-" + [guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($Source))
  }

  # Copy original content
  Copy-Item -LiteralPath $Source -Destination $targetPath -Force

  # Grow by appending deterministic pattern
  if ($ExtraBytes -gt 0) {
    # Use [IO.File]::OpenWrite to append without BOM
    $fs = $null
    try {
      $fs = [IO.File]::OpenWrite($targetPath)
      $fs.Seek(0, [IO.SeekOrigin]::End) | Out-Null
      $pattern = [byte[]]::new($ExtraBytes)
      for ($i = 0; $i -lt $ExtraBytes; $i++) {
        $pattern[$i] = [byte][char]'A'
      }
      $fs.Write($pattern, 0, $ExtraBytes)
    } finally {
      if ($fs) { $fs.Dispose() }
    }
  }

  $finalInfo = Get-Item -LiteralPath $targetPath
  [PSCustomObject]@{
    Path = $targetPath
    FinalLength = $finalInfo.Length
  }
}

function Invoke-AtomicSwap {
  <#
  .SYNOPSIS
    Atomically swaps replacement file over original with retry logic.
  .PARAMETER Original
    Path to original file to be replaced.
  .PARAMETER Replacement
    Path to replacement file (will be moved).
  .PARAMETER MaxRetries
    Maximum retry attempts on transient failures (default 12).
  .PARAMETER RetryDelayMs
    Delay in milliseconds between retries (default 50).
  .OUTPUTS
    Boolean success indicator.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Original,
    [Parameter(Mandatory)]
    [string]$Replacement,
    [int]$MaxRetries = 12,
    [int]$RetryDelayMs = 50
  )

  if (-not (Test-Path -LiteralPath $Replacement)) {
    throw "Replacement file not found: $Replacement"
  }

  # Clear read-only attribute on original if it exists
  if (Test-Path -LiteralPath $Original) {
    $origItem = Get-Item -LiteralPath $Original -Force
    if ($origItem.IsReadOnly) {
      $origItem.IsReadOnly = $false
    }
  }

  $attempt = 0
  $lastError = $null

  while ($attempt -le $MaxRetries) {
    try {
      Move-Item -LiteralPath $Replacement -Destination $Original -Force -ErrorAction Stop
      return $true
    } catch {
      $lastError = $_
      $isTransient = $_.Exception -is [System.IO.IOException]
                     -or $_.Exception -is [System.UnauthorizedAccessException]
      
      if (-not $isTransient -or $attempt -ge $MaxRetries) {
        throw "Atomic swap failed after $($attempt + 1) attempts: $lastError"
      }

      $attempt++
      Start-Sleep -Milliseconds $RetryDelayMs
    }
  }

  throw "Atomic swap failed after $MaxRetries retries: $lastError"
}
