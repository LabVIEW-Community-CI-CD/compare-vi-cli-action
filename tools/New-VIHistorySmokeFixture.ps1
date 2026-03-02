param(
  [Parameter(Mandatory = $true)]
  [string]$OutputRoot,
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  } catch {
    if ([System.IO.Path]::IsPathRooted($Path)) {
      return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
  }
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value,
    [int]$Depth = 12
  )

  $dir = Split-Path -Parent $Path
  if ($dir) {
    [void](Ensure-Directory -Path $dir)
  }
  $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$DestPath
  )

  if ([string]::IsNullOrWhiteSpace($DestPath)) { return }
  $line = '{0}={1}' -f $Key, $Value
  Add-Content -LiteralPath $DestPath -Value $line -Encoding utf8
}

$resultsDir = Ensure-Directory -Path (Resolve-FullPath -Path $OutputRoot)
$defaultDir = Ensure-Directory -Path (Join-Path $resultsDir 'default')
$attributesDir = Ensure-Directory -Path (Join-Path $resultsDir 'attributes')
$defaultPairDir = Ensure-Directory -Path (Join-Path $defaultDir 'pair-001')

$reportPath = Join-Path $defaultPairDir 'compare-report.html'
@'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Sample VI Compare Report</title>
  </head>
  <body>
    <h1>VI Compare Report</h1>
    <p>Deterministic smoke fixture report.</p>
  </body>
</html>
'@ | Set-Content -LiteralPath $reportPath -Encoding utf8

$generatedAt = '2026-01-01T00:00:00.000Z'
$targetPath = 'Fixtures/Sample.vi'

$defaultBaseRef = '1111111111111111111111111111111111111111'
$defaultHeadRef = '2222222222222222222222222222222222222222'
$attrBaseRef = '3333333333333333333333333333333333333333'
$attrHeadRef = '4444444444444444444444444444444444444444'

$defaultManifestPath = Join-Path $defaultDir 'manifest.json'
$attributesManifestPath = Join-Path $attributesDir 'manifest.json'

$defaultManifest = [ordered]@{
  schema = 'vi-compare/history@v1'
  generatedAt = $generatedAt
  targetPath = $targetPath
  mode = 'default'
  slug = 'default'
  reportFormat = 'html'
  resultsDir = $defaultDir
  stats = [ordered]@{
    processed = 1
    diffs = 1
    errors = 0
    missing = 0
    stopReason = 'complete'
    lastDiffIndex = 1
    lastDiffCommit = $defaultHeadRef
    categoryCounts = [ordered]@{
      'block-diagram' = 1
    }
    bucketCounts = [ordered]@{
      'functional-behavior' = 1
    }
  }
  status = 'ok'
  comparisons = @(
    [ordered]@{
      index = 1
      base = [ordered]@{
        ref = $defaultBaseRef
        short = $defaultBaseRef.Substring(0, 12)
      }
      head = [ordered]@{
        ref = $defaultHeadRef
        short = $defaultHeadRef.Substring(0, 12)
      }
      lineage = [ordered]@{
        type = 'merge-parent'
        parentIndex = 2
        parentCount = 2
        mergeCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        branchHead = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        depth = 1
      }
      outName = 'pair-001'
      result = [ordered]@{
        diff = $true
        exitCode = 1
        duration_s = 0.42
        status = 'completed'
        reportPath = $reportPath
        categories = @('Block Diagram Functional')
        categoryDetails = @(
          [ordered]@{
            slug = 'block-diagram'
            label = 'Block diagram'
            classification = 'signal'
          }
        )
        categoryBuckets = @('functional-behavior')
        categoryBucketDetails = @(
          [ordered]@{
            slug = 'functional-behavior'
            label = 'Functional behavior'
            classification = 'signal'
          }
        )
        highlights = @('Block diagram change detected')
      }
    }
  )
}
Write-JsonFile -Path $defaultManifestPath -Value $defaultManifest -Depth 12

$attributesManifest = [ordered]@{
  schema = 'vi-compare/history@v1'
  generatedAt = $generatedAt
  targetPath = $targetPath
  mode = 'attributes'
  slug = 'attributes'
  reportFormat = 'html'
  resultsDir = $attributesDir
  stats = [ordered]@{
    processed = 1
    diffs = 0
    errors = 0
    missing = 0
    stopReason = 'complete'
    lastDiffIndex = $null
    lastDiffCommit = $null
    categoryCounts = [ordered]@{
      'attributes' = 1
    }
    bucketCounts = [ordered]@{
      'metadata' = 1
    }
  }
  status = 'ok'
  comparisons = @(
    [ordered]@{
      index = 1
      base = [ordered]@{
        ref = $attrBaseRef
        short = $attrBaseRef.Substring(0, 12)
      }
      head = [ordered]@{
        ref = $attrHeadRef
        short = $attrHeadRef.Substring(0, 12)
      }
      lineage = [ordered]@{
        type = 'mainline'
        parentIndex = 1
        parentCount = 1
        depth = 0
      }
      outName = 'pair-001'
      result = [ordered]@{
        diff = $false
        exitCode = 0
        duration_s = 0.18
        status = 'completed'
        categories = @('VI Attribute')
        categoryDetails = @(
          [ordered]@{
            slug = 'attributes'
            label = 'Attributes'
            classification = 'neutral'
          }
        )
        categoryBuckets = @('metadata')
        categoryBucketDetails = @(
          [ordered]@{
            slug = 'metadata'
            label = 'Metadata'
            classification = 'neutral'
          }
        )
      }
    }
  )
}
Write-JsonFile -Path $attributesManifestPath -Value $attributesManifest -Depth 12

$suiteManifestPath = Join-Path $resultsDir 'manifest.json'
$suiteManifest = [ordered]@{
  schema = 'vi-compare/history-suite@v1'
  generatedAt = $generatedAt
  targetPath = $targetPath
  requestedStartRef = 'HEAD^'
  startRef = 'HEAD'
  endRef = ''
  maxPairs = 2
  failFast = $false
  failOnDiff = $false
  reportFormat = 'html'
  resultsDir = $resultsDir
  modes = @(
    [ordered]@{
      name = 'default'
      slug = 'default'
      reportFormat = 'html'
      flags = @('-nobd', '-noattr')
      manifestPath = $defaultManifestPath
      resultsDir = $defaultDir
      stats = $defaultManifest.stats
      status = 'ok'
    },
    [ordered]@{
      name = 'attributes'
      slug = 'attributes'
      reportFormat = 'html'
      flags = @('-nobd')
      manifestPath = $attributesManifestPath
      resultsDir = $attributesDir
      stats = $attributesManifest.stats
      status = 'ok'
    }
  )
  stats = [ordered]@{
    modes = 2
    processed = 2
    diffs = 1
    errors = 0
    missing = 0
    categoryCounts = [ordered]@{
      'block-diagram' = 1
      'attributes' = 1
    }
    bucketCounts = [ordered]@{
      'functional-behavior' = 1
      'metadata' = 1
    }
  }
  status = 'ok'
}
Write-JsonFile -Path $suiteManifestPath -Value $suiteManifest -Depth 12

$historyContextPath = Join-Path $resultsDir 'history-context.json'
$historyContext = [ordered]@{
  schema = 'vi-compare/history-context@v1'
  generatedAt = $generatedAt
  targetPath = $targetPath
  requestedStartRef = 'HEAD^'
  startRef = 'HEAD'
  maxPairs = 2
  comparisons = @(
    [ordered]@{
      mode = 'default'
      index = 1
      base = [ordered]@{
        full = $defaultBaseRef
        short = $defaultBaseRef.Substring(0, 12)
        subject = 'Baseline commit'
        author = 'Smoke Fixture'
        authorEmail = 'smoke@example.com'
        date = '2026-01-01T00:00:00Z'
      }
      head = [ordered]@{
        full = $defaultHeadRef
        short = $defaultHeadRef.Substring(0, 12)
        subject = 'Functional block diagram update'
        author = 'Smoke Fixture'
        authorEmail = 'smoke@example.com'
        date = '2026-01-01T00:01:00Z'
      }
      lineage = [ordered]@{
        type = 'merge-parent'
        parentIndex = 2
        parentCount = 2
        mergeCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        branchHead = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        depth = 1
      }
      lineageLabel = 'Merge parent #2 depth 1'
      result = [ordered]@{
        diff = $true
        status = 'completed'
        duration_s = 0.42
        reportPath = $reportPath
        categories = @('Block Diagram Functional')
        categoryDetails = @(
          [ordered]@{
            slug = 'block-diagram'
            label = 'Block diagram'
            classification = 'signal'
          }
        )
        categoryBuckets = @('functional-behavior')
        categoryBucketDetails = @(
          [ordered]@{
            slug = 'functional-behavior'
            label = 'Functional behavior'
            classification = 'signal'
          }
        )
        highlights = @('Block diagram change detected')
      }
      highlights = @('Block diagram change detected')
    },
    [ordered]@{
      mode = 'attributes'
      index = 1
      base = [ordered]@{
        full = $attrBaseRef
        short = $attrBaseRef.Substring(0, 12)
        subject = 'Attribute baseline'
        author = 'Smoke Fixture'
        authorEmail = 'smoke@example.com'
        date = '2026-01-01T00:02:00Z'
      }
      head = [ordered]@{
        full = $attrHeadRef
        short = $attrHeadRef.Substring(0, 12)
        subject = 'Attribute cleanup'
        author = 'Smoke Fixture'
        authorEmail = 'smoke@example.com'
        date = '2026-01-01T00:03:00Z'
      }
      lineage = [ordered]@{
        type = 'mainline'
        parentIndex = 1
        parentCount = 1
        depth = 0
      }
      lineageLabel = 'Mainline'
      result = [ordered]@{
        diff = $false
        status = 'completed'
        duration_s = 0.18
        categories = @('VI Attribute')
        categoryDetails = @(
          [ordered]@{
            slug = 'attributes'
            label = 'Attributes'
            classification = 'neutral'
          }
        )
        categoryBuckets = @('metadata')
        categoryBucketDetails = @(
          [ordered]@{
            slug = 'metadata'
            label = 'Metadata'
            classification = 'neutral'
          }
        )
        highlights = @()
      }
      highlights = @()
    }
  )
}
Write-JsonFile -Path $historyContextPath -Value $historyContext -Depth 12

Write-GitHubOutput -Key 'suite-manifest-path' -Value $suiteManifestPath -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'history-context-path' -Value $historyContextPath -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'results-dir' -Value $resultsDir -DestPath $GitHubOutputPath

Write-Host ("VI history smoke fixture created under {0}" -f $resultsDir)
Write-Host ("Suite manifest: {0}" -f $suiteManifestPath)
Write-Host ("History context: {0}" -f $historyContextPath)
