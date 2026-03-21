#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$CatalogPath = 'fixtures/headless-corpus/sample-vi-corpus.targets.json',
  [string]$ResultsRoot = 'tests/results/_agent/headless-sample-corpus',
  [string]$ReportPath,
  [string]$MarkdownPath,
  [switch]$SkipSchemaValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$PathValue
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)

  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 32)
}

function Convert-ToRepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue
  )

  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $PathValue
  $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $resolved)
  if ($relative -eq '.') {
    return '.'
  }

  if ($relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or
      $relative.StartsWith('..' + [System.IO.Path]::AltDirectorySeparatorChar) -or
      $relative -eq '..') {
    return ($resolved -replace '\\', '/')
  }

  return ($relative -replace '\\', '/')
}

function Invoke-SchemaValidation {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string]$DataPath
  )

  $runner = Join-Path $RepoRoot 'tools' 'npm' 'run-script.mjs'
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Schema validation runner not found at '$runner'."
  }

  $output = & node $runner 'schema:validate' '--' '--schema' $SchemaPath '--data' $DataPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Schema validation failed for '$DataPath': $message"
  }
}

function Get-StringArray {
  param([AllowNull()][object]$Value)

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    if ([string]::IsNullOrWhiteSpace([string]$item)) {
      continue
    }

    $items.Add(([string]$item).Trim()) | Out-Null
  }

  return @($items.ToArray())
}

function Test-IsPinnedCommit {
  param([AllowNull()][string]$Value)

  return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[0-9a-f]{40}$')
}

function Test-IsGitHubRepoUrl {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  try {
    $uri = [System.Uri]$Value
    return $uri.Scheme -in @('https', 'http') -and $uri.Host -eq 'github.com'
  } catch {
    return $false
  }
}

function Test-IsGitHubEvidenceUrl {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  try {
    $uri = [System.Uri]$Value
    return $uri.Scheme -in @('https', 'http') -and $uri.Host -eq 'github.com' -and $uri.AbsolutePath -match '/(pull|actions/runs|issues/.+#issuecomment-)'
  } catch {
    return $false
  }
}

function Test-IsRepoSlug {
  param([AllowNull()][string]$Value)

  return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
}

function Test-RenderStrategyAlignment {
  param(
    [Parameter(Mandatory)][string]$ChangeKind,
    [Parameter(Mandatory)][string]$CertificationSurface,
    [Parameter(Mandatory)][string]$Operation
  )

  switch ($CertificationSurface) {
    'vi-history' {
      return $ChangeKind -eq 'modified' -and $Operation -eq 'Compare-VIHistory'
    }
    'compare-report' {
      return $ChangeKind -eq 'modified' -and $Operation -eq 'CreateComparisonReport'
    }
    'print-single-file' {
      return $ChangeKind -in @('added', 'deleted') -and $Operation -eq 'PrintToSingleFileHtml'
    }
    default {
      return $false
    }
  }
}

$repoRoot = Resolve-RepoRoot
$catalogResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CatalogPath
if (-not (Test-Path -LiteralPath $catalogResolved -PathType Leaf)) {
  throw "Headless sample VI corpus catalog not found at '$catalogResolved'."
}

$catalogSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'headless-sample-vi-corpus-targets-v1.schema.json'
$evaluationSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'headless-sample-vi-corpus-evaluation-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $catalogSchemaPath -DataPath $catalogResolved
}

$catalog = Read-JsonFile -Path $catalogResolved
$resultsRootResolved = Ensure-Directory -Path (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot)
$reportResolved = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  Join-Path $resultsRootResolved 'headless-sample-vi-corpus-evaluation.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReportPath
}
$markdownResolved = if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
  Join-Path $resultsRootResolved 'headless-sample-vi-corpus-evaluation.md'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $MarkdownPath
}
Ensure-Directory -Path (Split-Path -Parent $reportResolved) | Out-Null
Ensure-Directory -Path (Split-Path -Parent $markdownResolved) | Out-Null

$policy = $catalog.admissionPolicy
$evaluatedTargets = New-Object System.Collections.Generic.List[object]
$driftCount = 0
$warningCount = 0
$okCount = 0
$acceptedCount = 0
$provisionalCount = 0
$rejectedCount = 0

foreach ($target in @($catalog.targets)) {
  $notes = New-Object System.Collections.Generic.List[string]
  $admissionState = [string]$target.admission.state
  switch ($admissionState) {
    'accepted' { $acceptedCount += 1 }
    'provisional' { $provisionalCount += 1 }
    'rejected' { $rejectedCount += 1 }
  }

  $repoSlug = [string]$target.source.repoSlug
  $repoUrl = [string]$target.source.repoUrl
  $license = [string]$target.source.licenseSpdx
  $targetPath = [string]$target.source.targetPath
  $changeKind = [string]$target.source.changeKind
  $pinnedCommit = [string]$target.source.pinnedCommit
  $surface = [string]$target.renderStrategy.certificationSurface
  $operation = [string]$target.renderStrategy.operation
  $planes = @(Get-StringArray -Value $target.renderStrategy.planeApplicability)
  $publicEvidence = @($target.publicEvidence)
  $operationPayloadMode = 'not-applicable'
  $operationPayloadProvenanceState = 'not-applicable'
  $operationPayloadTracked = $true
  $operationPayloadSourceValid = $true
  $operationPayloadLicenseDeclared = $true
  $operationPayloadPromotable = $true

  $hasPublicRepo = Test-IsGitHubRepoUrl -Value $repoUrl
  if (-not $hasPublicRepo) {
    $notes.Add('Repository URL must be a public GitHub repository URL.') | Out-Null
  }

  $evidenceUrlsValid = $publicEvidence.Count -gt 0
  $successfulWorkflowEvidenceCount = 0
  foreach ($evidence in $publicEvidence) {
    if (-not (Test-IsGitHubEvidenceUrl -Value ([string]$evidence.url))) {
      $evidenceUrlsValid = $false
    }
    if ([string]$evidence.kind -eq 'workflow-run' -and [string]$evidence.status -eq 'success') {
      $successfulWorkflowEvidenceCount += 1
    }
  }
  if (-not $evidenceUrlsValid) {
    $notes.Add('One or more public evidence URLs are missing or not GitHub-backed workflow/PR/comment links.') | Out-Null
  }

  $hasLicense = -not [string]::IsNullOrWhiteSpace($license)
  if (-not $hasLicense) {
    $notes.Add('No declared license is recorded for this seed.') | Out-Null
  }

  $hasPinnedCommit = Test-IsPinnedCommit -Value $pinnedCommit
  if (-not $hasPinnedCommit) {
    $notes.Add('Pinned commit must be a 40-character lowercase git SHA.') | Out-Null
  }

  $renderStrategyAligned = Test-RenderStrategyAlignment -ChangeKind $changeKind -CertificationSurface $surface -Operation $operation
  if (-not $renderStrategyAligned) {
    $notes.Add(("Render strategy is not coherent for changeKind='{0}', surface='{1}', operation='{2}'." -f $changeKind, $surface, $operation)) | Out-Null
  }

  $requiresOperationPayload = $surface -eq 'print-single-file'
  if ($requiresOperationPayload) {
    if (-not ($target.PSObject.Properties['operationPayload'] -and $target.operationPayload)) {
      $operationPayloadTracked = $false
      $operationPayloadSourceValid = $false
      $operationPayloadLicenseDeclared = $false
      $operationPayloadPromotable = $false
      $notes.Add('PrintToSingleFileHtml targets must declare operationPayload provenance.') | Out-Null
    } else {
      $operationPayloadMode = [string]$target.operationPayload.mode
      $operationPayloadProvenanceState = [string]$target.operationPayload.provenanceState
      $payloadSourceRepoSlug = if ($target.operationPayload.PSObject.Properties['sourceRepositorySlug']) { [string]$target.operationPayload.sourceRepositorySlug } else { '' }
      $payloadSourceRepoUrl = if ($target.operationPayload.PSObject.Properties['sourceRepositoryUrl']) { [string]$target.operationPayload.sourceRepositoryUrl } else { '' }
      $payloadSourceLicense = if ($target.operationPayload.PSObject.Properties['sourceLicenseSpdx']) { [string]$target.operationPayload.sourceLicenseSpdx } else { '' }
      $payloadNotes = @(Get-StringArray -Value $target.operationPayload.notes)

      if ($operationPayloadMode -eq 'additional-operation-directory') {
        $operationPayloadSourceValid = (Test-IsRepoSlug -Value $payloadSourceRepoSlug) -and
          (Test-IsGitHubRepoUrl -Value $payloadSourceRepoUrl) -and
          ($payloadNotes.Count -gt 0)
        if (-not $operationPayloadSourceValid) {
          $notes.Add('Custom operation payload provenance is incomplete or not GitHub-backed.') | Out-Null
        }

        $operationPayloadLicenseDeclared = -not [string]::IsNullOrWhiteSpace($payloadSourceLicense)
        if (-not $operationPayloadLicenseDeclared) {
          $notes.Add('Custom operation payload has no declared license.') | Out-Null
        }

        $operationPayloadPromotable = $operationPayloadProvenanceState -eq 'accepted' -and
          $operationPayloadSourceValid -and
          $operationPayloadLicenseDeclared
        if (-not $operationPayloadPromotable) {
          $notes.Add('Custom operation payload is not promotable for accepted certification use.') | Out-Null
        }
      } elseif ($operationPayloadMode -eq 'builtin') {
        $operationPayloadSourceValid = $true
        $operationPayloadLicenseDeclared = $true
        $operationPayloadPromotable = $operationPayloadProvenanceState -eq 'accepted'
        if (-not $operationPayloadPromotable) {
          $notes.Add('Builtin operation payload metadata must still be marked accepted before promotion.') | Out-Null
        }
      } else {
        $operationPayloadSourceValid = $false
        $operationPayloadLicenseDeclared = $false
        $operationPayloadPromotable = $false
        $notes.Add(("Unsupported operation payload mode '{0}'." -f $operationPayloadMode)) | Out-Null
      }
    }
  }

  $fixturePaths = @()
  if ($target.PSObject.Properties['localEvidence'] -and $target.localEvidence) {
    $fixturePaths = @(Get-StringArray -Value $target.localEvidence.fixturePaths)
  }
  $existingFixtureCount = 0
  $fixturePathsResolved = $true
  foreach ($pathValue in $fixturePaths) {
    $resolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $pathValue
    if (Test-Path -LiteralPath $resolved) {
      $existingFixtureCount += 1
    } else {
      $fixturePathsResolved = $false
      $notes.Add(("Local fixture path was not found: {0}" -f $pathValue)) | Out-Null
    }
  }

  if ($admissionState -eq 'accepted' -and $policy.acceptedTargetsRequirePublicGithubEvidence -and $successfulWorkflowEvidenceCount -lt 1) {
    $notes.Add('Accepted targets require at least one successful workflow-run evidence URL.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and $policy.acceptedTargetsRequireLicense -and -not $hasLicense) {
    $notes.Add('Accepted targets require a declared license.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and $policy.acceptedTargetsRequirePinnedCommit -and -not $hasPinnedCommit) {
    $notes.Add('Accepted targets require a pinned commit.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and -not $hasPublicRepo) {
    $notes.Add('Accepted targets require a public GitHub repository URL.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and -not $evidenceUrlsValid) {
    $notes.Add('Accepted targets require valid GitHub evidence URLs.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and -not $renderStrategyAligned) {
    $notes.Add('Accepted targets require a render strategy aligned with the change kind.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and
      $policy.acceptedTargetsRequirePromotableOperationPayload -and
      $requiresOperationPayload -and
      -not $operationPayloadPromotable) {
    $notes.Add('Accepted targets require a promotable custom operation payload.') | Out-Null
  }
  if ($admissionState -eq 'accepted' -and -not $fixturePathsResolved -and $fixturePaths.Count -gt 0) {
    $notes.Add('Accepted target declared local fixture lineage but one or more fixture paths were missing.') | Out-Null
  }
  if ($admissionState -eq 'provisional' -and -not $policy.provisionalTargetsAllowed) {
    $notes.Add('Catalog policy currently does not allow provisional targets.') | Out-Null
  }

  $status = 'ok'
  if ($admissionState -eq 'accepted' -and @($notes).Count -gt 0) {
    $status = 'drift'
    $driftCount += 1
  } elseif ($admissionState -ne 'accepted' -and @($notes).Count -gt 0) {
    $status = 'warning'
    $warningCount += 1
  } else {
    $okCount += 1
  }

  $evaluatedTargets.Add([ordered]@{
      id = [string]$target.id
      admissionState = $admissionState
      status = $status
      repoSlug = $repoSlug
      targetPath = $targetPath
      changeKind = $changeKind
      certificationSurface = $surface
      operation = $operation
      operationPayloadMode = $operationPayloadMode
      operationPayloadProvenanceState = $operationPayloadProvenanceState
      planeApplicability = @($planes)
      publicEvidenceCount = $publicEvidence.Count
      successfulWorkflowEvidenceCount = $successfulWorkflowEvidenceCount
      localFixtureCount = $fixturePaths.Count
      localFixtureExistingCount = $existingFixtureCount
      checks = [ordered]@{
        publicRepo = $hasPublicRepo
        githubEvidenceUrls = $evidenceUrlsValid
        licenseDeclared = $hasLicense
        pinnedCommit = $hasPinnedCommit
        successfulWorkflowEvidence = $successfulWorkflowEvidenceCount -gt 0
        renderStrategyAligned = $renderStrategyAligned
        localFixturePathsResolved = $fixturePathsResolved
        operationPayloadTracked = $operationPayloadTracked
        operationPayloadSourceValid = $operationPayloadSourceValid
        operationPayloadLicenseDeclared = $operationPayloadLicenseDeclared
        operationPayloadPromotable = $operationPayloadPromotable
      }
      notes = @($notes.ToArray())
    }) | Out-Null
}

$summary = [ordered]@{
  targetCount = @($catalog.targets).Count
  acceptedCount = $acceptedCount
  provisionalCount = $provisionalCount
  rejectedCount = $rejectedCount
  okCount = $okCount
  warningCount = $warningCount
  driftCount = $driftCount
}

$report = [ordered]@{
  schema = 'vi-headless/sample-corpus-evaluation@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  catalogPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $catalogResolved
  overallStatus = if ($driftCount -gt 0) { 'drift' } else { 'ok' }
  summary = $summary
  targets = @($evaluatedTargets.ToArray())
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportResolved -Encoding utf8

$markdownLines = @(
  '# Headless Sample VI Corpus Evaluation',
  '',
  ('- Catalog: `{0}`' -f $report.catalogPath),
  ('- Overall Status: `{0}`' -f $report.overallStatus),
  ('- Accepted Targets: `{0}`' -f $summary.acceptedCount),
  ('- Provisional Targets: `{0}`' -f $summary.provisionalCount),
  ('- Drift Targets: `{0}`' -f $summary.driftCount),
  ('- Warning Targets: `{0}`' -f $summary.warningCount),
  '',
  '| Target | Admission | Status | Surface | Payload | Planes | Evidence |',
  '| --- | --- | --- | --- | --- | --- |'
)
foreach ($target in @($report.targets)) {
  $payloadLabel = if ([string]$target.operationPayloadMode -eq 'not-applicable') {
    'n/a'
  } else {
    ('{0}/{1}' -f [string]$target.operationPayloadMode, [string]$target.operationPayloadProvenanceState)
  }
  $markdownLines += ('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` successful workflow run(s) |' -f
    $target.id,
    $target.admissionState,
    $target.status,
    $target.certificationSurface,
    $payloadLabel,
    ((@($target.planeApplicability) | ForEach-Object { [string]$_ }) -join ', '),
    $target.successfulWorkflowEvidenceCount)
  if (@($target.notes).Count -gt 0) {
    $markdownLines += ''
    $markdownLines += ('## {0}' -f $target.id)
    foreach ($note in @($target.notes)) {
      $markdownLines += ('- {0}' -f [string]$note)
    }
  }
}
$markdownLines += ''
$markdownLines | Set-Content -LiteralPath $markdownResolved -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $evaluationSchemaPath -DataPath $reportResolved
}

if ($report.overallStatus -eq 'drift') {
  $reportRelative = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved
  throw "Headless sample VI corpus evaluation detected drift. See '$reportRelative'."
}

Write-Host ("Headless sample VI corpus evaluation passed. Report: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved))
return [pscustomobject]$report
