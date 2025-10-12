#Requires -Version 7.0
param(
  [string]$Image = 'compare-validate',
  [string]$Workspace = (Get-Location).Path,
  [string]$LogDirectory = 'tests/results/_validate-container',
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Tool {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required tool not found: $Name"
  }
}

Assert-Tool docker

$workspacePath = Resolve-Path -LiteralPath $Workspace
if (-not $workspacePath) {
  throw "Unable to resolve workspace path: $Workspace"
}

$logFullDir = Join-Path $workspacePath $LogDirectory
if (-not (Test-Path -LiteralPath $logFullDir)) {
  New-Item -ItemType Directory -Force -Path $logFullDir | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logFullDir "prechecks-$timestamp.log"

$workspaceMount = "$($workspacePath.Path):/workspace"

# Optional npm cache mount (best effort)
$npmCache = Join-Path $env:USERPROFILE '.npm'
$npmMount = $null
if (Test-Path -LiteralPath $npmCache) {
  $npmMount = "${npmCache}:/root/.npm"
}

$dockerArgs = @(
  'run','--rm',
  '--workdir','/workspace',
  '-v', $workspaceMount
)

if ($npmMount) {
  $dockerArgs += @('-v', $npmMount)
}

if ($env:GITHUB_TOKEN) {
  $dockerArgs += @('-e', 'GITHUB_TOKEN')
}

$dockerArgs += $Image
$dockerArgs += @('-NoLogo','-NoProfile','-File','./tools/Run-OneButtonValidate.ps1')

Write-Host ("[validate-container] docker {0}" -f ($dockerArgs -join ' '))

$logWriter = New-Object System.IO.StreamWriter($logPath,$false,[System.Text.Encoding]::UTF8)
try {
  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = 'docker'
  $processInfo.Arguments = ($dockerArgs -join ' ')
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $processInfo.UseShellExecute = $false
  $process = [System.Diagnostics.Process]::Start($processInfo)
  while (-not $process.HasExited) {
    $line = $process.StandardOutput.ReadLine()
    if ($null -ne $line) {
      Write-Host $line
      $logWriter.WriteLine($line)
    }
    Start-Sleep -Milliseconds 100
  }
  while (-not $process.StandardOutput.EndOfStream) {
    $line = $process.StandardOutput.ReadLine()
    Write-Host $line
    $logWriter.WriteLine($line)
  }
  while (-not $process.StandardError.EndOfStream) {
    $errLine = $process.StandardError.ReadLine()
    Write-Host $errLine
    $logWriter.WriteLine($errLine)
  }
  $exit = $process.ExitCode
} finally {
  $logWriter.Flush(); $logWriter.Dispose()
}

if ($exit -ne 0) {
  throw "Container prechecks failed (exit=$exit). See $logPath"
}

Write-Host ("[validate-container] Completed successfully. Log: {0}" -f $logPath)

if ($PassThru) {
  [pscustomobject]@{ LogPath = $logPath }
}
