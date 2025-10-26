param(
  [Parameter(Mandatory = $true)]
  [string]$ViPath,
  [string]$StartRef = 'HEAD',
  [int]$MaxPairs = 10,
  [switch]$HtmlReport = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedRepoRelativePath {
  param(
    [string]$InputPath,
    [string]$RepoRoot
  )

  if ([string]::IsNullOrWhiteSpace($InputPath)) {
    return $null
  }

  try {
    $normalizedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $candidateFullPath = if ([System.IO.Path]::IsPathRooted($InputPath)) {
      [System.IO.Path]::GetFullPath($InputPath)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $InputPath))
    }
  } catch {
    return $null
  }

  if (-not $candidateFullPath.StartsWith($normalizedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  return ($candidateFullPath.Substring($normalizedRepoRoot.Length).TrimStart('\','/') -replace '\\','/')
}

function Test-ViTrackedAtRef {
  param(
    [string]$Ref,
    [string]$RepoRelativePath
  )

  if ([string]::IsNullOrWhiteSpace($Ref) -or [string]::IsNullOrWhiteSpace($RepoRelativePath)) {
    return $false
  }

  & git --no-pager cat-file -e ("{0}:{1}" -f $Ref, $RepoRelativePath) 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Get-ViCandidatesAtRef {
  param([string]$Ref)

  if ([string]::IsNullOrWhiteSpace($Ref)) {
    return @()
  }

  $candidates = & git --no-pager ls-tree -r --name-only $Ref 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $candidates) {
    return ,@()
  }

  $normalized = @()
  foreach ($entry in @($candidates)) {
    if (-not [string]::IsNullOrWhiteSpace($entry) -and $entry -like '*.vi') {
      $normalized += $entry
    }
  }

  return ,$normalized
}

function Get-CompareHistoryGuidance {
  param(
    [string]$ErrorMessage,
    [string]$RepoRelativePath,
    [string]$StartRef,
    [int]$MaxPairs,
    [string]$ResultsDir
  )

  if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
    return $null
  }

  $message = $ErrorMessage.Trim()
  $guidance = $null

  if ($message -match '^No commits found for .+ reachable from .+$') {
    $guidance = ("No commits for `{0}` are reachable from `{1}`. Increase `-MaxPairs` (current: {2}) or choose an earlier start ref (for example `develop~5`). `git log --follow -- {0}` can help confirm history." -f $RepoRelativePath, $StartRef, $MaxPairs)
  } elseif ($message -eq 'No comparison modes executed.') {
    $guidance = ("No compare modes ran for `{0}`. Ensure the VI has prior revisions relative to `{1}` and that history automation hasn't pruned the branch." -f $RepoRelativePath, $StartRef)
  } elseif ($message -match 'git merge-base --is-ancestor failed') {
    $guidance = ("Git merge-base failed while walking history. Fetch latest commits and verify `{0}` exists on `{1}`." -f $RepoRelativePath, $StartRef)
  } elseif ($message -match 'Compare script not found') {
    $guidance = 'The compare helper script was not located. Run tools/priority/bootstrap.ps1 or restore the tools directory before retrying.'
  } elseif ($message -match 'No valid comparison modes resolved') {
    $guidance = 'No comparison modes resolved. Confirm the history helper configuration includes at least one mode (default is `default`).'
  } elseif ($message -match 'git must be available on PATH') {
    $guidance = 'Git is required for history capture. Install git and ensure it is on PATH.'
  }

  if (-not $guidance) {
    $guidance = ("Inspect `{0}` for partial artifacts and review previous output for more details." -f $ResultsDir)
  }

  return $guidance
}

function Get-CommitMetadata {
  param([string]$Ref)

  if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }

  $format = '%H|%h|%an|%ad|%s'
  $data = & git --no-pager show --no-patch --date=iso8601-strict --pretty=format:$format $Ref 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $data) { return $null }

  $parts = $data -split '\|',5
  if ($parts.Count -lt 5) { return $null }

  return [ordered]@{
    full    = $parts[0]
    short   = $parts[1]
    author  = $parts[2]
    date    = $parts[3]
    subject = $parts[4]
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$historyResultsDir = Join-Path $repoRoot 'tests' 'results' 'ref-compare' 'history'

Push-Location $repoRoot
try {
  $repoRelativePath = Get-NormalizedRepoRelativePath -InputPath $ViPath -RepoRoot $repoRoot
  if (-not $repoRelativePath) {
    Write-Warning ("VI '{0}' is outside the repository root or could not be normalized. Provide a path relative to '{1}'." -f $ViPath, $repoRoot)
    return
  }

  $refToCheck = if ([string]::IsNullOrWhiteSpace($StartRef)) { 'HEAD' } else { $StartRef }

  if (-not (Test-ViTrackedAtRef -Ref $refToCheck -RepoRelativePath $repoRelativePath)) {
    Write-Warning ("VI '{0}' (resolved to '{1}') was not found at ref '{2}'. Choose a commit or branch where the file exists." -f $ViPath, $repoRelativePath, $refToCheck)

    $candidateSample = Get-ViCandidatesAtRef -Ref $refToCheck
    if ($candidateSample.Count -gt 0) {
      $previewCount = [Math]::Min($candidateSample.Count, 5)
      Write-Host ("Available VI paths at '{0}' (showing {1}):" -f $refToCheck, $previewCount)
      for ($index = 0; $index -lt $previewCount; $index++) {
        Write-Host ("  - {0}" -f $candidateSample[$index])
      }
      if ($candidateSample.Count -gt $previewCount) {
        Write-Host ("  ... ({0} more)" -f ($candidateSample.Count - $previewCount))
      }
    }

    Write-Host ("Tip: git ls-tree {0} --name-only | Select-String '\\.vi$'" -f $refToCheck)
    return
  }

  try {
    pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1') `
      -TargetPath $ViPath `
      -StartRef $StartRef `
      -MaxPairs $MaxPairs `
      -Detailed `
      -RenderReport:$HtmlReport.IsPresent
  } catch {
    $compareMessage = $_.Exception.Message
    $guidance = Get-CompareHistoryGuidance -ErrorMessage $compareMessage -RepoRelativePath $repoRelativePath -StartRef $refToCheck -MaxPairs $MaxPairs -ResultsDir $historyResultsDir
    Write-Error ("Compare-VIHistory.ps1 failed: {0}" -f $compareMessage)
    if ($guidance) {
      Write-Warning $guidance
    }
    return
  }

  $manifestPath = Join-Path $historyResultsDir 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Warning "Manifest not generated at expected path: $manifestPath"
    return
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 8
  if (-not $manifest.PSObject.Properties['modes']) {
    Write-Warning 'History manifest does not contain mode data; skipping summary preview.'
    return
  }

  $comparisonDetails = @()
  foreach ($mode in @($manifest.modes)) {
    if (-not $mode.manifestPath) { continue }
    if (-not (Test-Path -LiteralPath $mode.manifestPath -PathType Leaf)) { continue }

    try {
      $modeManifest = Get-Content -LiteralPath $mode.manifestPath -Raw | ConvertFrom-Json -Depth 8
    } catch {
      Write-Warning ("Unable to parse mode manifest '{0}': {1}" -f $mode.manifestPath, $_.Exception.Message)
      continue
    }

    foreach ($comparison in @($modeManifest.comparisons)) {
      $baseMeta = Get-CommitMetadata -Ref $comparison.base.ref
      if (-not $baseMeta) {
        $baseMeta = [ordered]@{
          full    = $comparison.base.ref
          short   = $comparison.base.short
          author  = $null
          date    = $null
          subject = $null
        }
      }

      $headMeta = Get-CommitMetadata -Ref $comparison.head.ref
      if (-not $headMeta) {
        $headMeta = [ordered]@{
          full    = $comparison.head.ref
          short   = $comparison.head.short
          author  = $null
          date    = $null
          subject = $null
        }
      }

      $resultNode = $null
      if ($comparison.PSObject.Properties['result']) {
        $resultNode = $comparison.result
      }

      $resultPayload = [ordered]@{}

      if ($resultNode) {
        if ($resultNode.PSObject.Properties['diff']) {
          $resultPayload.diff = [bool]$resultNode.diff
        }
        if ($resultNode.PSObject.Properties['exitCode']) {
          $resultPayload.exitCode = $resultNode.exitCode
        }
        if ($resultNode.PSObject.Properties['duration_s']) {
          $resultPayload.duration_s = $resultNode.duration_s
        }
        if ($resultNode.PSObject.Properties['summaryPath'] -and $resultNode.summaryPath) {
          $resultPayload.summaryPath = $resultNode.summaryPath
        }
        if ($resultNode.PSObject.Properties['reportPath'] -and $resultNode.reportPath) {
          $resultPayload.reportPath = $resultNode.reportPath
        }
        if ($resultNode.PSObject.Properties['reportHtml'] -and $resultNode.reportHtml) {
          $resultPayload.reportHtml = $resultNode.reportHtml
        }
        if ($resultNode.PSObject.Properties['artifactDir'] -and $resultNode.artifactDir) {
          $resultPayload.artifactDir = $resultNode.artifactDir
        }
        if ($resultNode.PSObject.Properties['execPath'] -and $resultNode.execPath) {
          $resultPayload.execPath = $resultNode.execPath
        }
        if ($resultNode.PSObject.Properties['command'] -and $resultNode.command) {
          $resultPayload.command = $resultNode.command
        }
        if ($resultNode.PSObject.Properties['includedAttributes'] -and $resultNode.includedAttributes) {
          $resultPayload.includedAttributes = @($resultNode.includedAttributes)
        }
        if ($resultNode.PSObject.Properties['status']) {
          $resultPayload.status = $resultNode.status
        }
        if ($resultNode.PSObject.Properties['message']) {
          $resultPayload.message = $resultNode.message
        }
      }

      $comparisonDetails += [pscustomobject]@{
        mode   = $mode.name
        index  = $comparison.index
        report = $comparison.outName
        base   = $baseMeta
        head   = $headMeta
        result = [pscustomobject]$resultPayload
      }
    }
  }

  if ($comparisonDetails.Count -gt 0) {
    $preview = [Math]::Min(3, $comparisonDetails.Count)
    Write-Host ("Comparison commit pairs ({0} total, showing {1}):" -f $comparisonDetails.Count, $preview) -ForegroundColor Yellow
    for ($i = 0; $i -lt $preview; $i++) {
      $entry = $comparisonDetails[$i]
      $baseLabel = if ($entry.base.subject) { "{0} ({1})" -f $entry.base.short, $entry.base.subject } else { $entry.base.short }
      $headLabel = if ($entry.head.subject) { "{0} ({1})" -f $entry.head.short, $entry.head.subject } else { $entry.head.short }
      $diffLabel = if ($entry.result.PSObject.Properties['diff']) {
        if ($entry.result.diff) { 'diff=yes' } else { 'diff=no' }
      } elseif ($entry.result.PSObject.Properties['status']) {
        "status=$($entry.result.status)"
      } else {
        'diff=n/a'
      }
      Write-Host ("  [{0} #{1}] {2} -> {3} ({4})" -f $entry.mode, $entry.index, $baseLabel, $headLabel, $diffLabel)
    }
    if ($comparisonDetails.Count -gt $preview) {
      Write-Host ("  ... ({0} more pair(s))" -f ($comparisonDetails.Count - $preview))
    }
  }

  $contextPath = Join-Path $historyResultsDir 'history-context.json'
  $contextPayload = [ordered]@{
    schema             = 'vi-compare/history-context@v1'
    generatedAt        = (Get-Date).ToString('o')
    targetPath         = $manifest.targetPath
    requestedStartRef  = $manifest.requestedStartRef
    startRef           = $manifest.startRef
    maxPairs           = $manifest.maxPairs
    comparisons        = $comparisonDetails
  }
  $contextPayload | ConvertTo-Json -Depth 6 | Out-File -FilePath $contextPath -Encoding utf8
  Write-Host ("History context summary written to {0}" -f $contextPath)

  $modeSummaryJson = ($manifest.modes | ConvertTo-Json -Depth 4)

  $historyReportPath = Join-Path $historyResultsDir 'history-report.md'
  $historyReportHtmlPath = $null
  if ($HtmlReport.IsPresent) {
    $historyReportHtmlPath = Join-Path $historyResultsDir 'history-report.html'
  }
  $historyRenderer = Join-Path $repoRoot 'tools' 'Render-VIHistoryReport.ps1'
  if (Test-Path -LiteralPath $historyRenderer -PathType Leaf) {
    $rendererArgs = @{
      ManifestPath       = $manifestPath
      HistoryContextPath = $contextPath
      OutputDir          = $historyResultsDir
      MarkdownPath       = $historyReportPath
    }
    if ($HtmlReport.IsPresent) {
      $rendererArgs['EmitHtml'] = $true
      $rendererArgs['HtmlPath'] = $historyReportHtmlPath
    }
    try {
      & $historyRenderer @rendererArgs | Out-Null
    } catch {
      Write-Warning ("Failed to render history report: {0}" -f $_.Exception.Message)
    }
  } else {
    Write-Warning ("VI history report renderer missing at {0}" -f $historyRenderer)
  }

  pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Publish-VICompareSummary.ps1') `
    -ManifestPath $manifestPath `
    -ModeSummaryJson $modeSummaryJson `
    -HistoryReportPath $historyReportPath `
    -HistoryReportHtmlPath $historyReportHtmlPath `
    -Issue 0 `
    -DryRun
} finally {
  Pop-Location
}
