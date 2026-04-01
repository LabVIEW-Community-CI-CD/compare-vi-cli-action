param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failurePayloadTool = Join-Path $PSScriptRoot 'PesterFailurePayload.ps1'
if (Test-Path -LiteralPath $failurePayloadTool -PathType Leaf) {
  . $failurePayloadTool
}

function Read-JsonObject {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    throw "JSON file not found: $PathValue"
  }

  return (Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)]$Payload,
    [int]$Depth = 10
  )

  $dir = Split-Path -Parent $PathValue
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Payload | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $PathValue -Encoding UTF8
}

function Set-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name,
    $Value
  )

  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) {
    $property.Value = $Value
  } else {
    Add-Member -InputObject $InputObject -Name $Name -MemberType NoteProperty -Value $Value
  }
}

function Write-LeakReportFromPayload {
  param(
    [Parameter(Mandatory = $true)][string]$ResultsDirectory,
    $Payload
  )

  if ($null -eq $Payload) {
    return $null
  }

  $outputPath = Join-Path $ResultsDirectory 'pester-leak-report.json'
  Write-JsonFile -PathValue $outputPath -Payload $Payload -Depth 10
  Write-Host ("Leak report written to: {0}" -f $outputPath) -ForegroundColor Gray
  return $outputPath
}

function Get-RunnerProfileSnapshot {
  $runnerProfile = $null
  try {
    if (-not (Get-Command -Name Get-RunnerProfile -ErrorAction SilentlyContinue)) {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      $runnerModule = Join-Path $repoRoot 'tools/RunnerProfile.psm1'
      if (Test-Path -LiteralPath $runnerModule -PathType Leaf) {
        Import-Module $runnerModule -Force
      }
    }
    if (Get-Command -Name Get-RunnerProfile -ErrorAction SilentlyContinue) {
      $runnerProfile = Get-RunnerProfile
    }
  } catch {}

  return $runnerProfile
}

function Get-ResultShapeSummary {
  param([Parameter(Mandatory = $true)][string]$ResultsDirectory)

  $diagJsonPath = Join-Path $ResultsDirectory 'result-shapes.json'
  if (-not (Test-Path -LiteralPath $diagJsonPath -PathType Leaf)) {
    return $null
  }

  try {
    $diagObj = Get-Content -LiteralPath $diagJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject]@{
      totalEntries = [int]$diagObj.totalEntries
      hasPath      = [int]$diagObj.overall.hasPath
      hasTags      = [int]$diagObj.overall.hasTags
    }
  } catch {
    return $null
  }
}

function Append-DiagnosticsFooterToSummary {
  param(
    [Parameter(Mandatory = $true)][string]$SummaryPath,
    [Parameter(Mandatory = $true)][string]$ResultsDirectory
  )

  $diag = Get-ResultShapeSummary -ResultsDirectory $ResultsDirectory
  if ($null -eq $diag) {
    return
  }

  function Get-PercentText {
    param([int]$Numerator,[int]$Denominator)
    if ($Denominator -le 0) { return '0%' }
    return ('{0:P1}' -f ([double]$Numerator / [double]$Denominator))
  }

  $footer = @()
  $footer += ''
  $footer += '---'
  $footer += 'Diagnostics Summary'
  $footer += ''
  $footer += ('Total entries: {0}' -f $diag.totalEntries)
  $footer += ('Has Path: {0} ({1})' -f $diag.hasPath, (Get-PercentText -Numerator $diag.hasPath -Denominator $diag.totalEntries))
  $footer += ('Has Tags: {0} ({1})' -f $diag.hasTags, (Get-PercentText -Numerator $diag.hasTags -Denominator $diag.totalEntries))
  Add-Content -LiteralPath $SummaryPath -Value ($footer -join "`n") -Encoding utf8
}

function Copy-CompareReportsAndWriteIndex {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ResultsDirectory
  )

  $destReport = Join-Path $ResultsDirectory 'compare-report.html'
  $candidates = @()
  $fixedCandidates = @(
    (Join-Path $RepoRoot 'tests' 'results' 'integration-compare-report.html'),
    (Join-Path $RepoRoot 'tests' 'results' 'compare-report.html'),
    (Join-Path $RepoRoot 'tests' 'results-single' 'pr-body-compare-report.html')
  )
  foreach ($pathValue in $fixedCandidates) {
    if (Test-Path -LiteralPath $pathValue -PathType Leaf) {
      try { $candidates += (Get-Item -LiteralPath $pathValue -ErrorAction SilentlyContinue) } catch {}
    }
  }
  try {
    $dynamic = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests' 'results') -Filter '*compare-report*.html' -Recurse -File -ErrorAction SilentlyContinue
    if ($dynamic) { $candidates += $dynamic }
  } catch {}

  function Normalize-PathValue {
    param(
      [string]$PathValue,
      [string]$BasePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }

    $candidate = $PathValue
    $basePath = if ([string]::IsNullOrWhiteSpace($BasePath)) { (Get-Location).ProviderPath } else { $BasePath }

    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
      try {
        $candidate = [System.IO.Path]::Combine($basePath, $candidate)
      } catch {
        return $candidate
      }
    }

    $attempts = @($candidate)
    if (-not $candidate.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
      if ($candidate.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        $attempts += ('\\?\UNC\' + $candidate.Substring(2))
      } else {
        $attempts += ('\\?\' + $candidate)
      }
    }

    foreach ($probe in $attempts) {
      try {
        $full = [System.IO.Path]::GetFullPath($probe)
        try {
          $resolved = Resolve-Path -LiteralPath $full -ErrorAction Stop
          if ($resolved -and $resolved.ProviderPath) {
            $full = $resolved.ProviderPath
          }
        } catch {}

        if ($full.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
          return ('\\' + $full.Substring(8))
        }
        if ($full.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
          return $full.Substring(4)
        }
        return $full
      } catch {}
    }

    return $candidate
  }

  if ($candidates.Count -gt 0) {
    $latest = $candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    try {
      $destFullPath = Normalize-PathValue -PathValue $destReport -BasePath $RepoRoot
      $latestFullPath = Normalize-PathValue -PathValue $latest.FullName -BasePath $RepoRoot
      $shouldCopyLatest = $true
      if ($latestFullPath -and $destFullPath -and [string]::Equals($latestFullPath, $destFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $shouldCopyLatest = $false
      }

      if ($shouldCopyLatest) {
        $destDir = [System.IO.Path]::GetDirectoryName($destReport)
        if ($destDir -and $latest.DirectoryName -and
            [string]::Equals($latest.DirectoryName, $destDir, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($latest.Name, 'compare-report.html', [System.StringComparison]::OrdinalIgnoreCase)) {
          $shouldCopyLatest = $false
        }
      }

      if ($shouldCopyLatest) {
        try {
          Copy-Item -LiteralPath $latest.FullName -Destination $destReport -Force -ErrorAction Stop
          Write-Host ("Compare report copied to: {0}" -f $destReport) -ForegroundColor Gray
        } catch {
          if (-not ($_.Exception -and $_.Exception.Message -match 'Cannot overwrite .+ with itself')) {
            Write-Warning "Failed to copy compare report: $_"
          }
        }
      }
    } catch {
      Write-Warning "Failed to copy compare report: $_"
    }

    foreach ($candidate in ($candidates | Sort-Object LastWriteTimeUtc)) {
      try {
        $destName = Split-Path -Leaf $candidate.FullName
        $destFull = Join-Path $ResultsDirectory $destName
        $destFullPath = Normalize-PathValue -PathValue $destFull -BasePath $RepoRoot
        $candidateFullPath = Normalize-PathValue -PathValue $candidate.FullName -BasePath $RepoRoot
        $shouldCopyCandidate = $true
        if ($destFullPath -and $candidateFullPath -and [string]::Equals($destFullPath, $candidateFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
          $shouldCopyCandidate = $false
        }
        if ($shouldCopyCandidate -and
            [string]::Equals($candidate.DirectoryName, $ResultsDirectory, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($candidate.Name, $destName, [System.StringComparison]::OrdinalIgnoreCase)) {
          $shouldCopyCandidate = $false
        }

        if ($shouldCopyCandidate) {
          try {
            Copy-Item -LiteralPath $candidate.FullName -Destination $destFull -Force -ErrorAction Stop
          } catch {
            if (-not ($_.Exception -and $_.Exception.Message -match 'Cannot overwrite .+ with itself')) {
              Write-Host "(warn) failed to copy extra report '$($candidate.FullName)': $_" -ForegroundColor DarkYellow
            }
          }
        }
      } catch {
        Write-Host "(warn) failed to copy extra report '$($candidate.FullName)': $_" -ForegroundColor DarkYellow
      }
    }
  }

  try {
    $indexPath = Join-Path $ResultsDirectory 'results-index.html'
    $reports = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*compare-report*.html' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    function Html-Encode {
      param([string]$TextValue)
      if ([string]::IsNullOrEmpty($TextValue)) { return '' }
      return $TextValue.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
    }
    $now = (Get-Date).ToString('u')
    $lines = @()
    $lines += '<!DOCTYPE html>'
    $lines += '<html lang="en">'
    $lines += '<head><meta charset="utf-8"/><title>Compare Reports Index</title><style>body{font-family:Segoe UI,SegoeUI,Helvetica,Arial,sans-serif;margin:16px} ul{line-height:1.6} .meta{color:#666} code{background:#f5f5f5;padding:2px 4px;border-radius:3px}</style></head>'
    $lines += '<body>'
    $lines += '<h1>Compare Reports Index</h1>'
    $lines += ("<p class='meta'>Generated at <code>{0}</code></p>" -f (Html-Encode -TextValue $now))
    $lines += ("<p>Total reports: <strong>{0}</strong> — canonical: <code>compare-report.html</code></p>" -f $reports.Count)
    if ($reports.Count -gt 0) {
      $lines += '<ul>'
      foreach ($report in $reports) {
        $nameEnc = Html-Encode -TextValue $report.Name
        $ts = Html-Encode -TextValue ($report.LastWriteTimeUtc.ToString('u'))
        $size = '{0:N0} bytes' -f $report.Length
        $meta = ('last write: {0}; size: {1}' -f $ts, (Html-Encode -TextValue $size))
        $canonicalTag = if ($report.Name -ieq 'compare-report.html') { ' <em class="meta">(canonical)</em>' } else { '' }
        $lines += ('<li><a href="{0}">{0}</a>{2} <span class=''meta''>({1})</span></li>' -f $nameEnc, $meta, $canonicalTag)
      }
      $lines += '</ul>'
    } else {
      $lines += '<p class="meta">No compare-report HTML files found in this results directory.</p>'
    }
    try {
      $diagTxt = Join-Path $ResultsDirectory 'result-shapes.txt'
      $diagJson = Join-Path $ResultsDirectory 'result-shapes.json'
      if ((Test-Path -LiteralPath $diagTxt) -or (Test-Path -LiteralPath $diagJson)) {
        $lines += '<hr/>'
        $lines += '<h3>Diagnostics</h3>'
        $lines += '<ul>'
        if (Test-Path -LiteralPath $diagTxt) { $lines += '<li><a href="result-shapes.txt">result-shapes.txt</a></li>' }
        if (Test-Path -LiteralPath $diagJson) { $lines += '<li><a href="result-shapes.json">result-shapes.json</a></li>' }
        $lines += '</ul>'
        if (Test-Path -LiteralPath $diagJson) {
          try {
            $diagObj = Get-Content -LiteralPath $diagJson -Raw | ConvertFrom-Json -ErrorAction Stop
            $totalEntries = [int]$diagObj.totalEntries
            $hasPath = [int]$diagObj.overall.hasPath
            $hasTags = [int]$diagObj.overall.hasTags
            function Get-PercentHtml {
              param([int]$Numerator,[int]$Denominator)
              if ($Denominator -le 0) { return '0%' }
              return ('{0:P1}' -f ([double]$Numerator / [double]$Denominator))
            }
            $lines += '<table style="border-collapse:collapse;margin-top:8px">'
            $lines += '<thead><tr><th style="text-align:left;padding:4px 8px;border-bottom:1px solid #e5e7eb">Metric</th><th style="text-align:right;padding:4px 8px;border-bottom:1px solid #e5e7eb">Count</th><th style="text-align:right;padding:4px 8px;border-bottom:1px solid #e5e7eb">Percent</th></tr></thead>'
            $lines += '<tbody>'
            $lines += ('<tr><td style="padding:4px 8px">Total entries</td><td style="text-align:right;padding:4px 8px">{0}</td><td style="text-align:right;padding:4px 8px">-</td></tr>' -f $totalEntries)
            $lines += ('<tr><td style="padding:4px 8px">Has Path</td><td style="text-align:right;padding:4px 8px">{0}</td><td style="text-align:right;padding:4px 8px">{1}</td></tr>' -f $hasPath, (Get-PercentHtml -Numerator $hasPath -Denominator $totalEntries))
            $lines += ('<tr><td style="padding:4px 8px">Has Tags</td><td style="text-align:right;padding:4px 8px">{0}</td><td style="text-align:right;padding:4px 8px">{1}</td></tr>' -f $hasTags, (Get-PercentHtml -Numerator $hasTags -Denominator $totalEntries))
            $lines += '</tbody></table>'
          } catch {}
        }
      }
    } catch {}
    $lines += '</body></html>'
    Set-Content -LiteralPath $indexPath -Value ($lines -join "`n") -Encoding UTF8
    Write-Host ("Results index written to: {0}" -f $indexPath) -ForegroundColor Gray
  } catch {
    Write-Host "(warn) failed to write results index: $_" -ForegroundColor DarkYellow
  }
}

function Write-ArtifactManifest {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$SummaryJsonPath,
    [Parameter(Mandatory = $true)][string]$ManifestVersion,
    [Parameter(Mandatory = $true)][string]$SummarySchemaVersion,
    [Parameter(Mandatory = $true)][string]$FailuresSchemaVersion,
    [Parameter(Mandatory = $true)][string]$LeakReportSchemaVersion,
    [Parameter(Mandatory = $true)][string]$DiagnosticsSchemaVersion
  )

  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  }

  $artifacts = @()
  $xmlPath = Join-Path $Directory 'pester-results.xml'
  if (Test-Path -LiteralPath $xmlPath) {
    $artifacts += [pscustomobject]@{ file = 'pester-results.xml'; type = 'nunitXml' }
  }
  $txtPath = Join-Path $Directory 'pester-summary.txt'
  if (Test-Path -LiteralPath $txtPath) {
    $artifacts += [pscustomobject]@{ file = 'pester-summary.txt'; type = 'textSummary' }
  }
  $cmpPath = Join-Path $Directory 'compare-report.html'
  if (Test-Path -LiteralPath $cmpPath) {
    $artifacts += [pscustomobject]@{ file = 'compare-report.html'; type = 'htmlCompare' }
  }
  $idxPath = Join-Path $Directory 'results-index.html'
  if (Test-Path -LiteralPath $idxPath) {
    $artifacts += [pscustomobject]@{ file = 'results-index.html'; type = 'htmlIndex' }
  }
  try {
    $extraHtml = @(Get-ChildItem -LiteralPath $Directory -Filter '*compare-report*.html' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'compare-report.html' })
    foreach ($item in $extraHtml) {
      $artifacts += [pscustomobject]@{ file = $item.Name; type = 'htmlCompare' }
    }
  } catch {}

  $jsonSummaryFile = Split-Path -Leaf $SummaryJsonPath
  if ($jsonSummaryFile) {
    $jsonPath = Join-Path $Directory $jsonSummaryFile
    if (Test-Path -LiteralPath $jsonPath) {
      $artifacts += [pscustomobject]@{ file = $jsonSummaryFile; type = 'jsonSummary'; schemaVersion = $SummarySchemaVersion }
    }
  }
  $failuresPath = Join-Path $Directory 'pester-failures.json'
  if (Test-Path -LiteralPath $failuresPath) {
    $artifacts += [pscustomobject]@{ file = 'pester-failures.json'; type = 'jsonFailures'; schemaVersion = $FailuresSchemaVersion }
  }
  $trailPath = Join-Path $Directory 'pester-artifacts-trail.json'
  if (Test-Path -LiteralPath $trailPath) {
    $artifacts += [pscustomobject]@{ file = 'pester-artifacts-trail.json'; type = 'jsonTrail' }
  }
  $sessionIdx = Join-Path $Directory 'session-index.json'
  if (Test-Path -LiteralPath $sessionIdx) {
    $artifacts += [pscustomobject]@{ file = 'session-index.json'; type = 'jsonSessionIndex' }
  }
  $leakPath = Join-Path $Directory 'pester-leak-report.json'
  if (Test-Path -LiteralPath $leakPath) {
    $artifacts += [pscustomobject]@{ file = 'pester-leak-report.json'; type = 'jsonLeaks'; schemaVersion = $LeakReportSchemaVersion }
  }
  $diagTxt = Join-Path $Directory 'result-shapes.txt'
  if (Test-Path -LiteralPath $diagTxt) {
    $artifacts += [pscustomobject]@{ file = 'result-shapes.txt'; type = 'textDiagnostics' }
  }
  $diagJson = Join-Path $Directory 'result-shapes.json'
  if (Test-Path -LiteralPath $diagJson) {
    $artifacts += [pscustomobject]@{ file = 'result-shapes.json'; type = 'jsonDiagnostics'; schemaVersion = $DiagnosticsSchemaVersion }
  }

  $metrics = $null
  try {
    if ($jsonSummaryFile) {
      $jsonPath = Join-Path $Directory $jsonSummaryFile
      if (Test-Path -LiteralPath $jsonPath) {
        $summaryJson = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $meanTestMs = if ($summaryJson.PSObject.Properties['meanTest_ms']) { $summaryJson.meanTest_ms } else { $null }
        $p95TestMs = if ($summaryJson.PSObject.Properties['p95Test_ms']) { $summaryJson.p95Test_ms } else { $null }
        $maxTestMs = if ($summaryJson.PSObject.Properties['maxTest_ms']) { $summaryJson.maxTest_ms } else { $null }
        $aggMsValue = $null
        if ($summaryJson.PSObject.Properties.Name -contains 'aggregatorBuildMs' -and $null -ne $summaryJson.aggregatorBuildMs) {
          $aggMsValue = $summaryJson.aggregatorBuildMs
        }
        $metrics = [pscustomobject]@{
          totalTests        = $summaryJson.total
          failed            = $summaryJson.failed
          skipped           = $summaryJson.skipped
          duration_s        = $summaryJson.duration_s
          meanTest_ms       = $meanTestMs
          p95Test_ms        = $p95TestMs
          maxTest_ms        = $maxTestMs
          aggregatorBuildMs = $aggMsValue
        }
      }
    }
  } catch {
    Write-Warning "Failed to enrich manifest metrics: $_"
  }

  $manifest = [pscustomobject]@{
    manifestVersion = $ManifestVersion
    generatedAt     = (Get-Date).ToString('o')
    artifacts       = $artifacts
    metrics         = $metrics
  }
  $manifestPath = Join-Path $Directory 'pester-artifacts.json'
  $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Encoding utf8 -ErrorAction Stop
  Write-Host ("Artifact manifest written to: {0}" -f $manifestPath) -ForegroundColor Gray
  return $manifestPath
}

function Write-SessionIndex {
  param(
    [Parameter(Mandatory = $true)][string]$ResultsDirectory,
    [Parameter(Mandatory = $true)][string]$SummaryJsonPath,
    [Parameter(Mandatory = $true)][bool]$IncludeIntegration,
    [Parameter()][string]$IntegrationMode,
    [Parameter()][string]$IntegrationSource,
    $PublicationContext
  )

  if (-not (Test-Path -LiteralPath $ResultsDirectory -PathType Container)) {
    throw "Results directory not found: $ResultsDirectory"
  }

  $idx = [ordered]@{
    schema             = 'session-index/v1'
    schemaVersion      = '1.0.0'
    generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    resultsDir         = $ResultsDirectory
    includeIntegration = $IncludeIntegration
    integrationMode    = $IntegrationMode
    integrationSource  = $IntegrationSource
    files              = [ordered]@{}
  }

  $runnerProfile = Get-RunnerProfileSnapshot
  $addIf = {
    param($Name, $File)
    $pathValue = Join-Path $ResultsDirectory $File
    if (Test-Path -LiteralPath $pathValue -PathType Leaf) {
      $idx.files[$Name] = $File
    }
  }

  & $addIf 'pesterResultsXml' 'pester-results.xml'
  & $addIf 'pesterSummaryTxt' 'pester-summary.txt'
  $jsonLeaf = Split-Path -Leaf $SummaryJsonPath
  if ($jsonLeaf) {
    & $addIf 'pesterSummaryJson' $jsonLeaf
    try {
      $sumPath = Join-Path $ResultsDirectory $jsonLeaf
      if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
        $summary = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $idx['summary'] = [ordered]@{
          total         = $summary.total
          passed        = $summary.passed
          failed        = $summary.failed
          errors        = $summary.errors
          skipped       = $summary.skipped
          duration_s    = $summary.duration_s
          meanTest_ms   = $summary.meanTest_ms
          p95Test_ms    = $summary.p95Test_ms
          maxTest_ms    = $summary.maxTest_ms
          schemaVersion = $summary.schemaVersion
        }
        $status = if (($summary.failed -gt 0) -or ($summary.errors -gt 0)) { 'fail' } else { 'ok' }
        $idx['status'] = $status
        $resultsRelative = $ResultsDirectory
        try {
          $cwd = (Get-Location).Path
          if ($resultsRelative.StartsWith($cwd, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $resultsRelative.Substring($cwd.Length).TrimStart('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
              $resultsRelative = $relative
            }
          }
        } catch {}
        $lines = @()
        $lines += '### Session Overview'
        $lines += ''
        $lines += ("- Status: {0}" -f $status)
        $lines += ("- Total: {0} | Passed: {1} | Failed: {2} | Errors: {3} | Skipped: {4}" -f $summary.total, $summary.passed, $summary.failed, $summary.errors, $summary.skipped)
        $lines += ("- Duration (s): {0}" -f $summary.duration_s)
        $lines += ("- Include Integration: {0}" -f $IncludeIntegration)
        $lines += ("- Integration Mode: {0}" -f $IntegrationMode)
        if ($IntegrationSource) { $lines += ("- Integration Source: {0}" -f $IntegrationSource) }
        $lines += ''
        $lines += 'Artifacts (paths):'
        $present = @()
        foreach ($key in @('pesterSummaryJson','pesterResultsXml','pesterSummaryTxt','artifactManifestJson','artifactTrailJson','leakReportJson','compareReportHtml','resultsIndexHtml')) {
          if ($idx.files[$key]) { $present += (Join-Path $resultsRelative $idx.files[$key]) }
        }
        foreach ($pathValue in $present) { $lines += ("- {0}" -f $pathValue) }
        $runnerName = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'name' -and $runnerProfile.name) { $runnerProfile.name } else { $env:RUNNER_NAME }
        $runnerOs = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'os' -and $runnerProfile.os) { $runnerProfile.os } else { $env:RUNNER_OS }
        $runnerArch = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'arch' -and $runnerProfile.arch) { $runnerProfile.arch } else { $env:RUNNER_ARCH }
        $runnerEnvironment = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'environment' -and $runnerProfile.environment) { $runnerProfile.environment } else { $env:RUNNER_ENVIRONMENT }
        $runnerMachine = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'machine' -and $runnerProfile.machine) { $runnerProfile.machine } else { [System.Environment]::MachineName }
        $runnerLabels = @()
        try {
          if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'labels') {
            $runnerLabels = @($runnerProfile.labels | Where-Object { $_ -and $_ -ne '' })
          } elseif (Get-Command -Name Get-RunnerLabels -ErrorAction SilentlyContinue) {
            $runnerLabels = @(Get-RunnerLabels | Where-Object { $_ -and $_ -ne '' })
          }
        } catch {}
        if ($runnerName -or $runnerOs -or $runnerArch -or $runnerEnvironment -or $runnerMachine -or ($runnerLabels -and $runnerLabels.Count -gt 0)) {
          $lines += ''
          $lines += '### Runner'
          $lines += ''
          if ($runnerName) { $lines += ("- Name: {0}" -f $runnerName) }
          if ($runnerOs -and $runnerArch) {
            $lines += ("- OS/Arch: {0}/{1}" -f $runnerOs, $runnerArch)
          } elseif ($runnerOs) {
            $lines += ("- OS: {0}" -f $runnerOs)
          } elseif ($runnerArch) {
            $lines += ("- Arch: {0}" -f $runnerArch)
          }
          if ($runnerEnvironment) { $lines += ("- Environment: {0}" -f $runnerEnvironment) }
          if ($runnerMachine) { $lines += ("- Machine: {0}" -f $runnerMachine) }
          if ($runnerLabels -and $runnerLabels.Count -gt 0) {
            $lines += ("- Labels: {0}" -f (($runnerLabels | Select-Object -Unique) -join ', '))
          }
        }
        $idx['stepSummary'] = ($lines -join "`n")
      }
    } catch {}
  }

  & $addIf 'pesterFailuresJson' 'pester-failures.json'
  & $addIf 'artifactManifestJson' 'pester-artifacts.json'
  & $addIf 'artifactTrailJson' 'pester-artifacts-trail.json'
  & $addIf 'dispatcherEventsNdjson' 'dispatcher-events.ndjson'
  & $addIf 'leakReportJson' 'pester-leak-report.json'
  & $addIf 'compareReportHtml' 'compare-report.html'
  & $addIf 'resultsIndexHtml' 'results-index.html'

  try {
    $driftRoot = Join-Path (Get-Location) 'results/fixture-drift'
    if (Test-Path -LiteralPath $driftRoot -PathType Container) {
      $dirs = Get-ChildItem -LiteralPath $driftRoot -Directory
      $tsDirs = @($dirs | Where-Object { $_.Name -match '^[0-9]{8}T[0-9]{6}Z$' })
      $latest = if ($tsDirs.Count -gt 0) { $tsDirs | Sort-Object Name -Descending | Select-Object -First 1 } else { $dirs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 }
      if ($latest) {
        $sumPath = Join-Path $latest.FullName 'drift-summary.json'
        $status = $null
        if (Test-Path -LiteralPath $sumPath) {
          try { $driftSummary = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop; $status = $driftSummary.status } catch {}
        }
        $idx['drift'] = [ordered]@{
          latestRunDir  = $latest.FullName
          latestSummary = if (Test-Path -LiteralPath $sumPath) { $sumPath } else { $null }
          status        = $status
        }
      }
    }
  } catch {}

  try {
    $runContext = [ordered]@{
      repository = $env:GITHUB_REPOSITORY
      ref        = (if ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF } else { $env:GITHUB_REF })
      commitSha  = $env:GITHUB_SHA
      workflow   = $env:GITHUB_WORKFLOW
      runId      = $env:GITHUB_RUN_ID
      runAttempt = $env:GITHUB_RUN_ATTEMPT
    }
    if ($env:GITHUB_JOB) { $runContext['job'] = $env:GITHUB_JOB }
    if ($env:RUNNER_NAME) { $runContext['runner'] = $env:RUNNER_NAME }
    if ($env:RUNNER_OS) { $runContext['runnerOS'] = $env:RUNNER_OS }
    if ($env:RUNNER_ARCH) { $runContext['runnerArch'] = $env:RUNNER_ARCH }
    if ($env:RUNNER_ENVIRONMENT) { $runContext['runnerEnvironment'] = $env:RUNNER_ENVIRONMENT }
    $machineName = try { [System.Environment]::MachineName } catch { $null }
    if ($machineName) { $runContext['runnerMachine'] = $machineName }
    if ($env:RUNNER_TRACKING_ID) { $runContext['runnerTrackingId'] = $env:RUNNER_TRACKING_ID }
    if ($env:ImageOS) { $runContext['runnerImageOS'] = $env:ImageOS }
    if ($env:ImageVersion) { $runContext['runnerImageVersion'] = $env:ImageVersion }
    if ($runnerProfile) {
      $map = @{
        name         = 'runner'
        os           = 'runnerOS'
        arch         = 'runnerArch'
        environment  = 'runnerEnvironment'
        machine      = 'runnerMachine'
        trackingId   = 'runnerTrackingId'
        imageOS      = 'runnerImageOS'
        imageVersion = 'runnerImageVersion'
      }
      foreach ($entry in $map.GetEnumerator()) {
        $source = $entry.Key
        $target = $entry.Value
        if ($runnerProfile.PSObject.Properties.Name -contains $source) {
          $value = $runnerProfile.$source
          if ($null -ne $value -and "$value" -ne '') {
            $runContext[$target] = $value
          }
        }
      }
      if ($runnerProfile.PSObject.Properties.Name -contains 'labels') {
        $labelValues = @($runnerProfile.labels | Where-Object { $_ -and $_ -ne '' })
        if ($labelValues.Count -gt 0) { $runContext['runnerLabels'] = $labelValues }
      }
    } elseif (Get-Command -Name Get-RunnerLabels -ErrorAction SilentlyContinue) {
      try {
        $labelsFallback = @(Get-RunnerLabels | Where-Object { $_ -and $_ -ne '' })
        if ($labelsFallback.Count -gt 0) { $runContext['runnerLabels'] = $labelsFallback }
      } catch {}
    }
    $idx['runContext'] = $runContext
    if ($env:GITHUB_REPOSITORY) {
      $repoUrl = "https://github.com/$($env:GITHUB_REPOSITORY)"
      $urls = [ordered]@{ repository = $repoUrl }
      if ($env:GITHUB_RUN_ID) { $urls.run = "$repoUrl/actions/runs/$($env:GITHUB_RUN_ID)" }
      if ($env:GITHUB_SHA) { $urls.commit = "$repoUrl/commit/$($env:GITHUB_SHA)" }
      try {
        $refValue = $env:GITHUB_REF
        if ($refValue -and $refValue -match 'refs/pull/(?<num>\d+)/') {
          $urls.pullRequest = "$repoUrl/pull/$($Matches.num)"
        }
      } catch {}
      $idx['urls'] = $urls
    }
  } catch {}

  try {
    $handshakeFiles = @(Get-ChildItem -Path $ResultsDirectory -Recurse -Filter 'handshake-*.json' -File -ErrorAction SilentlyContinue)
    if ($handshakeFiles.Count -gt 0) {
      $sortedHandshake = @($handshakeFiles | Sort-Object LastWriteTimeUtc)
      $last = $sortedHandshake[-1]
      $lastRel = try { ($last.FullName).Substring(((Get-Location).Path).Length).TrimStart('\','/') } catch { $last.Name }
      $lastJson = $null
      try { $lastJson = Get-Content -LiteralPath $last.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
      $lastPhase = if ($lastJson.name) { [string]$lastJson.name } else { [string]([IO.Path]::GetFileNameWithoutExtension($last.Name) -replace '^handshake-','') }
      $lastAtUtc = if ($lastJson.atUtc) { [string]$lastJson.atUtc } else { $last.LastWriteTimeUtc.ToString('o') }
      $lastStatus = if ($lastJson.status) { [string]$lastJson.status } else { $null }
      $markerRel = @()
      foreach ($file in $sortedHandshake) {
        $relativePath = try { ($file.FullName).Substring(((Get-Location).Path).Length).TrimStart('\','/') } catch { $file.Name }
        $markerRel += $relativePath
      }
      if (-not $idx['runContext']) { $idx['runContext'] = [ordered]@{} }
      $idx.runContext['handshake'] = [ordered]@{
        lastPhase   = $lastPhase
        lastAtUtc   = $lastAtUtc
        lastStatus  = $lastStatus
        markerPaths = $markerRel
      }
      try {
        $handshakeLines = @()
        $handshakeLines += ("- Handshake Last Phase: {0}" -f $lastPhase)
        if ($lastStatus) { $handshakeLines += ("- Handshake Last Status: {0}" -f $lastStatus) }
        $firstTwo = @($markerRel | Select-Object -First 2)
        foreach ($marker in $firstTwo) { $handshakeLines += ("- Marker: {0}" -f $marker) }
        if ($idx['stepSummary']) {
          $idx['stepSummary'] = $idx['stepSummary'] + "`n`n" + ($handshakeLines -join "`n")
        } else {
          $idx['stepSummary'] = ($handshakeLines -join "`n")
        }
      } catch {}
    }
  } catch {}

  if ($PublicationContext) {
    try {
      $publicationLines = @()
      $selectedTests = @()
      if ($PublicationContext.PSObject.Properties.Name -contains 'selectedTests') {
        $selectedTests = @($PublicationContext.selectedTests | Where-Object { $_ -and "$_" -ne '' })
      }
      $publicationLines += '### Selected Tests'
      $publicationLines += ''
      if ($selectedTests.Count -eq 0) {
        $publicationLines += '- (none)'
      } else {
        foreach ($testName in ($selectedTests | Select-Object -Unique)) {
          $publicationLines += ("- {0}" -f $testName)
        }
      }
      $publicationLines += ''
      $publicationLines += '### Configuration'
      $publicationLines += ''
      $publicationLines += ("- IncludeIntegration: {0}" -f $IncludeIntegration)
      $publicationLines += ("- Integration Mode: {0}" -f $IntegrationMode)
      if ($IntegrationSource) { $publicationLines += ("- Integration Source: {0}" -f $IntegrationSource) }
      if ($PublicationContext.PSObject.Properties.Name -contains 'discovery' -and $PublicationContext.discovery) {
        $publicationLines += ("- Discovery: {0}" -f [string]$PublicationContext.discovery)
      }
      if ($PublicationContext.PSObject.Properties.Name -contains 'rerunCommand' -and $PublicationContext.rerunCommand) {
        $publicationLines += ''
        $publicationLines += '### Re-run (gh)'
        $publicationLines += ''
        $publicationLines += ("- {0}" -f [string]$PublicationContext.rerunCommand)
      }
      if ($PublicationContext.PSObject.Properties.Name -contains 'guard' -and $PublicationContext.guard) {
        $publicationLines += ''
        $publicationLines += '### Guard'
        $publicationLines += ''
        $publicationLines += ("- Enabled: {0}" -f [bool]$PublicationContext.guard.enabled)
        $publicationLines += ("- Heartbeats: {0}" -f [int]$PublicationContext.guard.heartbeats)
        if ($PublicationContext.guard.PSObject.Properties.Name -contains 'heartbeatPath' -and $PublicationContext.guard.heartbeatPath) {
          $publicationLines += ("- Heartbeat file: {0}" -f [string]$PublicationContext.guard.heartbeatPath)
        }
        if ($PublicationContext.guard.PSObject.Properties.Name -contains 'partialLogPath' -and $PublicationContext.guard.partialLogPath) {
          $publicationLines += ("- Partial log: {0}" -f [string]$PublicationContext.guard.partialLogPath)
        }
      }
      if ($idx['stepSummary']) {
        $idx['stepSummary'] = $idx['stepSummary'] + "`n`n" + ($publicationLines -join "`n")
      } else {
        $idx['stepSummary'] = ($publicationLines -join "`n")
      }
    } catch {
      Write-Warning ("Failed to enrich session index publication block: {0}" -f $_.Exception.Message)
    }
  }

  $dest = Join-Path $ResultsDirectory 'session-index.json'
  $idx | ConvertTo-Json -Depth 6 | Out-File -FilePath $dest -Encoding utf8 -ErrorAction Stop
  Write-Host ("Session index written to: {0}" -f $dest) -ForegroundColor Gray
  return $dest
}

$resolvedContextPath = [System.IO.Path]::GetFullPath($ContextPath)
$context = Read-JsonObject -PathValue $resolvedContextPath
$resultsDir = [System.IO.Path]::GetFullPath([string]$context.resultsDir)
$repoRoot = [System.IO.Path]::GetFullPath([string]$context.repoRoot)
$jsonSummaryLeaf = if ([string]::IsNullOrWhiteSpace([string]$context.jsonSummaryPath)) {
  'pester-summary.json'
} else {
  Split-Path -Leaf ([string]$context.jsonSummaryPath)
}
$summaryPath = Join-Path $resultsDir 'pester-summary.txt'
$summaryJsonPath = Join-Path $resultsDir $jsonSummaryLeaf
$artifactTrailPath = Join-Path $resultsDir 'pester-artifacts-trail.json'
$publicationContext = if ($context.PSObject.Properties['publication']) { $context.publication } else { $null }
$publicationToolPath = Join-Path $PSScriptRoot 'Invoke-PesterExecutionPublication.ps1'
$summaryTextValue = if ($context.PSObject.Properties['summaryText']) { [string]$context.summaryText } else { $null }
$hasSummaryPayload = [bool]$context.PSObject.Properties['summaryPayload']
$hasArtifactTrail = [bool]$context.PSObject.Properties['artifactTrail']
$hasLeakReportPayload = [bool]$context.PSObject.Properties['leakReportPayload']

if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($summaryTextValue)) {
  $summaryTextValue | Out-File -FilePath $summaryPath -Encoding utf8 -ErrorAction Stop
  Append-DiagnosticsFooterToSummary -SummaryPath $summaryPath -ResultsDirectory $resultsDir
  Write-Host ("Summary written to: {0}" -f $summaryPath) -ForegroundColor Gray
}

$summaryPayloadToWrite = if ($hasSummaryPayload -and $null -ne $context.summaryPayload) { $context.summaryPayload } else { $null }
if ($null -ne $summaryPayloadToWrite) {
  try {
    Sync-PesterFailurePayload -Directory $resultsDir -SummaryObject $summaryPayloadToWrite -SchemaVersion ([string]$context.failuresSchemaVersion) | Out-Null
  } catch {
    Write-Warning ("Failed to synchronize failure-detail payload during finalize: {0}" -f $_.Exception.Message)
  }
  $summaryPayloadToWrite | ConvertTo-Json -Depth 12 | Out-File -FilePath $summaryJsonPath -Encoding utf8 -ErrorAction Stop
  Write-Host ("JSON summary written to: {0}" -f $summaryJsonPath) -ForegroundColor Gray
}

if ($hasArtifactTrail -and $null -ne $context.artifactTrail) {
  $context.artifactTrail | ConvertTo-Json -Depth 8 | Out-File -FilePath $artifactTrailPath -Encoding utf8 -ErrorAction Stop
  Write-Host ("Artifact trail written to: {0}" -f $artifactTrailPath) -ForegroundColor Gray
}

if ($hasLeakReportPayload -and $null -ne $context.leakReportPayload) {
  Write-LeakReportFromPayload -ResultsDirectory $resultsDir -Payload $context.leakReportPayload | Out-Null
}

Copy-CompareReportsAndWriteIndex -RepoRoot $repoRoot -ResultsDirectory $resultsDir
$sessionIndexPath = Write-SessionIndex -ResultsDirectory $resultsDir -SummaryJsonPath $jsonSummaryLeaf -IncludeIntegration ([bool]$context.includeIntegration) -IntegrationMode ([string]$context.integrationMode) -IntegrationSource ([string]$context.integrationSource) -PublicationContext $publicationContext
$manifestPath = Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath $jsonSummaryLeaf -ManifestVersion ([string]$context.manifestVersion) -SummarySchemaVersion ([string]$context.summarySchemaVersion) -FailuresSchemaVersion ([string]$context.failuresSchemaVersion) -LeakReportSchemaVersion ([string]$context.leakReportSchemaVersion) -DiagnosticsSchemaVersion ([string]$context.diagnosticsSchemaVersion)

if (Test-Path -LiteralPath $publicationToolPath -PathType Leaf) {
  & $publicationToolPath -ContextPath $resolvedContextPath | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Invoke-PesterExecutionPublication.ps1 failed with exit code $LASTEXITCODE."
  }
}

if ($env:GITHUB_OUTPUT) {
  "summary_path=$summaryPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "summary_json_path=$summaryJsonPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "session_index_path=$sessionIndexPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "manifest_path=$manifestPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester execution finalize' -ForegroundColor Cyan
Write-Host ("summary      : {0}" -f $summaryPath)
Write-Host ("summary json : {0}" -f $summaryJsonPath)
Write-Host ("session idx  : {0}" -f $sessionIndexPath)
Write-Host ("manifest     : {0}" -f $manifestPath)

exit 0
