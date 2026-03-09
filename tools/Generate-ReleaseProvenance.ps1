param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactsRoot,

  [string]$OutputPath = 'provenance.json'
)

$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $ArtifactsRoot).Path
$provenancePath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath
} else {
  Join-Path $resolvedRoot $OutputPath
}

$assetFiles = Get-ChildItem -LiteralPath $resolvedRoot -File |
  Where-Object { $_.Name -match '\.zip$|\.tar\.gz$|^SHA256SUMS\.txt$|^sbom\.spdx\.json$' }

$assetEntries = foreach ($file in $assetFiles) {
  [ordered]@{
    name = $file.Name
    path = "artifacts/cli/$($file.Name)"
    sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    sizeBytes = $file.Length
  }
}

$payload = [ordered]@{
  schema = 'run-provenance/v1'
  schemaVersion = '1.0.0'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  repository = $env:GITHUB_REPOSITORY
  workflow = $env:GITHUB_WORKFLOW
  eventName = $env:GITHUB_EVENT_NAME
  runId = $env:GITHUB_RUN_ID
  runAttempt = $env:GITHUB_RUN_ATTEMPT
  ref = $env:GITHUB_REF
  refName = $env:GITHUB_REF_NAME
  branch = $env:GITHUB_REF_NAME
  headRef = $env:GITHUB_HEAD_REF
  baseRef = $env:GITHUB_BASE_REF
  headSha = $env:GITHUB_SHA
  releaseAssets = @($assetEntries)
}

$json = $payload | ConvertTo-Json -Depth 10
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($provenancePath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "Provenance metadata written to $provenancePath"
