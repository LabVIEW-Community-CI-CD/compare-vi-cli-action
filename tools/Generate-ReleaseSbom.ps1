param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactsRoot,

  [string]$OutputPath = 'sbom.spdx.json',

  [string]$ToolName = 'comparevi-cli-release-pipeline'
)

$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $ArtifactsRoot).Path
$sbomPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath
} else {
  Join-Path $resolvedRoot $OutputPath
}

$allFiles = Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse |
  Where-Object { $_.FullName -ne $sbomPath }

$documentNamespace = "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/sbom/$([Guid]::NewGuid())"
$documentDescribes = 'SPDXRef-Package-comparevi-cli-release'

$fileEntries = @()
$fileRefs = @()

foreach ($file in $allFiles) {
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $file.FullName).Replace('\\', '/')
  $spdxRef = ('SPDXRef-File-' + ($relativePath -replace '[^A-Za-z0-9\.-]', '-')).TrimEnd('-')

  $fileEntries += [ordered]@{
    fileName = "./$relativePath"
    SPDXID = $spdxRef
    checksums = @(
      [ordered]@{
        algorithm = 'SHA256'
        checksumValue = $hash
      }
    )
    licenseConcluded = 'NOASSERTION'
    copyrightText = 'NOASSERTION'
  }

  $fileRefs += [ordered]@{
    relatedSpdxElement = $spdxRef
    relationshipType = 'CONTAINS'
  }
}

$sbom = [ordered]@{
  spdxVersion = 'SPDX-2.3'
  dataLicense = 'CC0-1.0'
  SPDXID = 'SPDXRef-DOCUMENT'
  name = 'comparevi-cli-release-assets'
  documentNamespace = $documentNamespace
  creationInfo = [ordered]@{
    created = (Get-Date).ToUniversalTime().ToString('o')
    creators = @(
      "Tool: $ToolName"
    )
  }
  packages = @(
    [ordered]@{
      name = 'comparevi-cli-release-assets'
      SPDXID = $documentDescribes
      downloadLocation = 'NOASSERTION'
      filesAnalyzed = $true
      licenseConcluded = 'NOASSERTION'
      copyrightText = 'NOASSERTION'
    }
  )
  files = $fileEntries
  relationships = @(
    [ordered]@{
      spdxElementId = 'SPDXRef-DOCUMENT'
      relationshipType = 'DESCRIBES'
      relatedSpdxElement = $documentDescribes
    }
  ) + @(
    foreach ($fileRef in $fileRefs) {
      [ordered]@{
        spdxElementId = $documentDescribes
        relationshipType = $fileRef.relationshipType
        relatedSpdxElement = $fileRef.relatedSpdxElement
      }
    }
  )
}

$json = $sbom | ConvertTo-Json -Depth 10
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($sbomPath, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host "SBOM written to $sbomPath"
