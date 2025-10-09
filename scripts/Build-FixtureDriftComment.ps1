function Get-FixtureDriftComment {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Marker,
    [Parameter(Mandatory)] [string] $Status,
    [string] $ExitCode,
    [Parameter(Mandatory)] [string] $RunUrl,
    [string[]] $ArtifactNames = @(),
    [string[]] $ArtifactPaths = @(),
    [object[]] $FileMetadata = @(),
    [string] $ReportPath
  )

  $lines = @()
  if (-not [string]::IsNullOrWhiteSpace($Marker)) {
    $lines += $Marker
  }

  $lines += 'Fixture Drift validation failed on this PR.'
  if ([string]::IsNullOrWhiteSpace($Status)) {
    $lines += 'Status: (not reported)'
  } elseif ([string]::IsNullOrWhiteSpace($ExitCode)) {
    $lines += "Status: $Status"
  } else {
    $lines += "Status: $Status (exit $ExitCode)"
  }

  $lines += ''
  $resolvedRunUrl = if ([string]::IsNullOrWhiteSpace($RunUrl)) { '#' } else { $RunUrl }
  $lines += "**Download artifacts**: Visit the [workflow run page]($resolvedRunUrl) and scroll to the Artifacts section at the bottom."
  $lines += ''

  if ($ArtifactNames -and $ArtifactNames.Count -gt 0) {
    $lines += 'Available artifacts:'
    foreach ($artifactName in $ArtifactNames) {
      if (-not [string]::IsNullOrWhiteSpace($artifactName)) {
        $lines += "- $artifactName"
      }
    }
    $lines += ''
  }

  $lines += 'Environment quick toggles:'
  $lines += '- DETECT_LEAKS=1 - emit leak report (tests/results/pester-leak-report.json)'
  $lines += '- CLEAN_AFTER=1 - best-effort stop LabVIEW/LVCompare after run'
  $lines += '- FAIL_ON_LEAKS=1 - fail when leaks are detected'
  $lines += ''
  $lines += 'Full reference: docs/ENVIRONMENT.md'

  if ($ArtifactPaths -and $ArtifactPaths.Count -gt 0) {
    $lines += ''
    $lines += 'Included artifact files:'
    foreach ($artifactPath in $ArtifactPaths) {
      if (-not [string]::IsNullOrWhiteSpace($artifactPath)) {
        $lines += "- $artifactPath"
      }
    }
  }

  if ($FileMetadata -and $FileMetadata.Count -gt 0) {
    $lines += ''
    $lines += 'Files on disk:'
    foreach ($file in $FileMetadata) {
      $path = $file.path
      $lastWriteTimeUtc = $file.lastWriteTimeUtc
      $length = $file.length

      if ($null -ne $length) {
        $lines += "- $path - $lastWriteTimeUtc ($length bytes)"
      } else {
        $lines += "- $path - $lastWriteTimeUtc"
      }
    }
  }

  if ($ReportPath -and (Test-Path -LiteralPath $ReportPath)) {
    try {
      $html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
      $encoded = $html.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
      $encoded = $encoded.Replace('"', '&quot;').Replace("'", '&#39;')
      if ($encoded.Length -gt 20000) {
        $encoded = $encoded.Substring(0, 20000) + "`n... (truncated)"
      }

      $lines += ''
      $lines += '<details><summary>Fixture Drift HTML report (inline preview)</summary>'
      $lines += ''
      $lines += '<pre>'
      foreach ($line in $encoded -split "`n") {
        $lines += $line.TrimEnd("`r")
      }
      $lines += '</pre>'
      $lines += '</details>'
    } catch {
      # Intentionally swallow read errors; HTML preview is optional.
    }
  }

  return ($lines -join "`n")
}

if ($PSCmdlet.MyInvocation.MyCommand.Module) {
  Export-ModuleMember -Function Get-FixtureDriftComment
}
