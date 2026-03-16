#Requires -Version 7.0
Set-StrictMode -Version Latest

function Initialize-DeliveryAgentDistScript {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$DistScript,

    [Parameter(Mandatory = $true)]
    [string]$WrapperLabel
  )

  if (Test-Path -LiteralPath $DistScript -PathType Leaf) {
    return
  }

  # Keep wrapper stdout machine-readable when we have to build the compiled fallback first.
  $buildOutput = & node (Join-Path $RepoRoot 'tools\npm\run-script.mjs') build 2>&1
  if ($LASTEXITCODE -eq 0) {
    return
  }

  $detail = ($buildOutput |
    ForEach-Object { $_.ToString().TrimEnd() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine

  if ([string]::IsNullOrWhiteSpace($detail)) {
    throw "TypeScript build failed for $WrapperLabel."
  }

  throw "TypeScript build failed for $WrapperLabel.`n$detail"
}

Export-ModuleMember -Function Initialize-DeliveryAgentDistScript
