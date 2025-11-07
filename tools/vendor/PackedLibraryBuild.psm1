<#
.SYNOPSIS
  Helper for orchestrating g-cli packed library builds across bitness targets.

.DESCRIPTION
  Executes a build/close/rename cycle for each provided target. Callers supply
  the vendor action scripts along with the argument lists to pass for each
  phase. This keeps orchestration logic centralised so multiple packages can
  share the same flow.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LVPackedLibraryBuild {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ScriptBlock]$InvokeAction,
    [Parameter(Mandatory)][string]$BuildScriptPath,
    [Parameter()][string]$CloseScriptPath,
    [Parameter(Mandatory)][string]$RenameScriptPath,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$BaseArtifactName,
    [Parameter(Mandatory)][hashtable[]]$Targets,
    [string[]]$CleanupPatterns = @('*.lvlibp'),
    [ScriptBlock]$OnBuildError
  )

  if (-not $Targets -or $Targets.Count -eq 0) {
    throw 'Invoke-LVPackedLibraryBuild requires at least one target configuration.'
  }

  foreach ($path in @($BuildScriptPath, $RenameScriptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required script '$path' was not found."
    }
  }

  if ($CloseScriptPath -and -not (Test-Path -LiteralPath $CloseScriptPath -PathType Leaf)) {
    throw "Close script '$CloseScriptPath' was not found."
  }

  $artifactDirectoryResolved = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
  $baseArtifactPath = Join-Path $artifactDirectoryResolved $BaseArtifactName

  foreach ($pattern in $CleanupPatterns) {
    if (-not $pattern) { continue }
    Get-ChildItem -LiteralPath $artifactDirectoryResolved -Filter $pattern -ErrorAction SilentlyContinue |
      ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      }
  }

  foreach ($target in $Targets) {
    if (-not $target.ContainsKey('BuildArguments')) {
      throw 'Each target must provide BuildArguments.'
    }

    $buildArgs = @($target.BuildArguments)
    try {
      & $InvokeAction $BuildScriptPath $buildArgs
    } catch {
      if ($OnBuildError) {
        $handled = & $OnBuildError -Target $target -ErrorRecord $_
        if ($handled) {
          throw $handled
        }
      }
      throw
    }

    if ($CloseScriptPath -and $target.ContainsKey('CloseArguments') -and $target.CloseArguments) {
      $closeArgs = @($target.CloseArguments)
      & $InvokeAction $CloseScriptPath $closeArgs
    }

    if (-not $target.ContainsKey('RenameArguments')) {
      throw 'Each target must provide RenameArguments.'
    }

    $renameArgs = @($target.RenameArguments) | ForEach-Object {
      if ($_ -eq '{{BaseArtifactPath}}') {
        return $baseArtifactPath
      }
      $_
    }

    if (-not ($renameArgs -contains $baseArtifactPath)) {
      # Ensure the current filename is populated when callers rely on the placeholder.
      for ($i = 0; $i -lt $renameArgs.Count; $i += 2) {
        if ($renameArgs[$i].TrimStart('-').ToLowerInvariant() -eq 'currentfilename') {
          if (-not $renameArgs[$i + 1]) {
            $renameArgs[$i + 1] = $baseArtifactPath
          }
          break
        }
      }
    }

    & $InvokeAction $RenameScriptPath $renameArgs
  }
}

Export-ModuleMember -Function Invoke-LVPackedLibraryBuild
