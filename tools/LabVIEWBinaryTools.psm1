#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KnownLabVIEWBinarySignatures = @('LVIN', 'LVCC')
$script:KnownLabVIEWBinaryExtensions = @(
  '.vi',
  '.vim',
  '.vit',
  '.ctl',
  '.ctt',
  '.lvclass',
  '.lvlib',
  '.lvproj',
  '.lvsc',
  '.lvlibp'
)
$script:LabVIEWBinarySignatureOffset = 8
$script:LabVIEWBinarySignatureLength = 4
$script:LabVIEWBinaryMinimumLength = $script:LabVIEWBinarySignatureOffset + $script:LabVIEWBinarySignatureLength

function Get-LabVIEWKnownFileExtensions {
  return @($script:KnownLabVIEWBinaryExtensions)
}

function Test-IsLabVIEWBinaryBytes {
  param(
    [byte[]]$Bytes
  )

  if ($null -eq $Bytes -or $Bytes.Length -lt $script:LabVIEWBinaryMinimumLength) {
    return $false
  }

  $signature = [System.Text.Encoding]::ASCII.GetString(
    $Bytes,
    $script:LabVIEWBinarySignatureOffset,
    $script:LabVIEWBinarySignatureLength
  )

  return $script:KnownLabVIEWBinarySignatures -contains $signature
}

function Test-IsLabVIEWBinaryFile {
  param(
    [Parameter(Mandatory)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $buffer = New-Object byte[] $script:LabVIEWBinaryMinimumLength
    $readCount = $stream.Read($buffer, 0, $buffer.Length)
    if ($readCount -lt $script:LabVIEWBinaryMinimumLength) {
      return $false
    }
    return Test-IsLabVIEWBinaryBytes -Bytes $buffer
  } finally {
    $stream.Dispose()
  }
}

function Invoke-GitBinaryContent {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo 'git'
  foreach ($arg in $Arguments) {
    [void]$psi.ArgumentList.Add($arg)
  }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $process = [System.Diagnostics.Process]::Start($psi)
  $stdoutStream = New-Object System.IO.MemoryStream
  try {
    $process.StandardOutput.BaseStream.CopyTo($stdoutStream)
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
      throw "git $($Arguments -join ' ') failed: $stderr"
    }
    return $stdoutStream.ToArray()
  } finally {
    $stdoutStream.Dispose()
    if ($null -ne $process) {
      $process.Dispose()
    }
  }
}

function Get-GitBlobBytes {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Ref) -or [string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $normalizedRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
  $normalizedGitPath = $Path.Replace('\', '/')
  return Invoke-GitBinaryContent -RepoPath $normalizedRepoPath -Arguments @(
    '-C',
    $normalizedRepoPath,
    'show',
    '--no-textconv',
    ("{0}:{1}" -f $Ref, $normalizedGitPath)
  )
}

function Test-IsLabVIEWBinaryAtGitPath {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Path
  )

  try {
    $bytes = Get-GitBlobBytes -RepoPath $RepoPath -Ref $Ref -Path $Path
    if ($null -eq $bytes) {
      return $false
    }
    return Test-IsLabVIEWBinaryBytes -Bytes $bytes
  } catch {
    return $false
  }
}

Export-ModuleMember -Function Get-LabVIEWKnownFileExtensions, Test-IsLabVIEWBinaryBytes, Test-IsLabVIEWBinaryFile, Get-GitBlobBytes, Test-IsLabVIEWBinaryAtGitPath
