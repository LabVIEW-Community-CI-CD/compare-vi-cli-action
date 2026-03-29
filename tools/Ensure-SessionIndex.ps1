[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub Actions annotations and local operator notices intentionally use the host stream.')]
param(
  [Parameter(Mandatory=$false)] [string]$ResultsDir = 'tests/results',
  [Parameter(Mandatory=$false)] [string]$SummaryJson = 'pester-summary.json',
  [Parameter(Mandatory=$false)] [switch]$DisableSessionIndexV2,
  [Parameter(Mandatory=$false)] [switch]$ForceSessionIndexV2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-HasProperty {
  param(
    [object]$Object,
    [string]$Name
  )

  return ($null -ne $Object) -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-PropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if (Test-HasProperty -Object $Object -Name $Name) {
    return $Object.$Name
  }

  return $null
}

function Get-TextValue {
  param([object]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  return $text.Trim()
}

function Get-StringArray {
  param([object]$Value)

  $items = New-Object System.Collections.ArrayList
  if ($null -eq $Value) {
    return ,([string[]]@())
  }

  foreach ($entry in @($Value)) {
    $text = Get-TextValue -Value $entry
    if ($text) {
      [void]$items.Add($text)
    }
  }

  return ,([string[]]@($items))
}

function Add-UniqueString {
  param(
    [System.Collections.ArrayList]$List,
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  if (-not $List.Contains($Value)) {
    [void]$List.Add($Value)
  }
}

function Get-ArtifactKindForFileKey {
  param([string]$Key)

  switch ($Key) {
    'pesterSummaryJson' { return 'summary' }
    'pesterSummaryTxt' { return 'summary' }
    'pesterResultsXml' { return 'report' }
    'compareReportHtml' { return 'report' }
    'resultsIndexHtml' { return 'report' }
    'dispatcherEventsNdjson' { return 'log' }
    'artifactManifestJson' { return 'artifact' }
    'artifactTrailJson' { return 'traceability' }
    'leakReportJson' { return 'report' }
    default { return 'custom' }
  }
}

function Resolve-SessionIndexV2BranchProtectionStatus {
  param([string]$Value)

  switch ((Get-TextValue -Value $Value)) {
    'fail' { return 'error' }
    'warn' { return 'warn' }
    default { return 'ok' }
  }
}

function Resolve-SessionIndexV2BranchProtectionReason {
  param([string]$Value)

  $normalized = Get-TextValue -Value $Value
  if (-not $normalized) {
    return $null
  }

  if ($normalized -in @(
      'aligned',
      'missing_required',
      'extra_required',
      'mismatch',
      'mapping_missing',
      'api_unavailable',
      'api_error',
      'api_forbidden'
    )) {
    return $normalized
  }

  return 'api_error'
}

function Resolve-SessionIndexV2ActualReason {
  param(
    [string]$ActualStatus,
    [string[]]$Notes
  )

  switch ((Get-TextValue -Value $ActualStatus)) {
    'unavailable' { return 'api_unavailable' }
    'error' {
      $joinedNotes = [string]::Join(' ', @($Notes))
      if ($joinedNotes -match '(?i)\b403\b' -or $joinedNotes -match '(?i)forbidden') {
        return 'api_forbidden'
      }
      return 'api_error'
    }
    default { return $null }
  }
}

function ConvertTo-SessionIndexV2Payload {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$SessionIndex
  )

  $runContext = Get-PropertyValue -Object $SessionIndex -Name 'runContext'
  $urls = Get-PropertyValue -Object $SessionIndex -Name 'urls'
  $summary = Get-PropertyValue -Object $SessionIndex -Name 'summary'
  $branchProtection = Get-PropertyValue -Object $SessionIndex -Name 'branchProtection'
  $files = Get-PropertyValue -Object $SessionIndex -Name 'files'

  $workflow = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'workflow')
  if (-not $workflow) {
    $workflow = Get-TextValue -Value $env:GITHUB_WORKFLOW
  }
  if (-not $workflow) {
    $workflow = 'unknown'
  }

  $run = [ordered]@{
    workflow = $workflow
  }

  $runId = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'runId')
  if (-not $runId) {
    $runId = Get-TextValue -Value $env:GITHUB_RUN_ID
  }
  if ($runId) {
    $run.id = $runId
  }

  $runAttempt = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'runAttempt')
  if (-not $runAttempt) {
    $runAttempt = Get-TextValue -Value $env:GITHUB_RUN_ATTEMPT
  }
  if ($runAttempt) {
    $parsedRunAttempt = 0
    if ([int]::TryParse($runAttempt, [ref]$parsedRunAttempt)) {
      $run.attempt = $parsedRunAttempt
    }
  }

  $job = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'job')
  if (-not $job) {
    $job = Get-TextValue -Value $env:GITHUB_JOB
  }
  if ($job) {
    $run.job = $job
  }

  $branch = Get-TextValue -Value (Get-PropertyValue -Object $branchProtection -Name 'branch')
  if (-not $branch) {
    $branch = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'ref')
  }
  if (-not $branch) {
    $branch = Get-TextValue -Value $env:GITHUB_REF_NAME
  }
  if (-not $branch) {
    $branch = Get-TextValue -Value $env:GITHUB_BASE_REF
  }
  if ($branch) {
    $run.branch = $branch
  }

  $commit = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'commitSha')
  if (-not $commit) {
    $commit = Get-TextValue -Value $env:GITHUB_SHA
  }
  if ($commit) {
    $run.commit = $commit
  }

  $repository = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'repository')
  if (-not $repository) {
    $repository = Get-TextValue -Value $env:GITHUB_REPOSITORY
  }
  if ($repository) {
    $run.repository = $repository
  }

  $triggerKind = Get-TextValue -Value $env:GITHUB_EVENT_NAME
  if ($triggerKind) {
    $run.trigger = [ordered]@{
      kind = $triggerKind
    }
  }

  $environment = [ordered]@{}
  $runner = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'runner')
  if (-not $runner) {
    $runner = Get-TextValue -Value $env:RUNNER_NAME
  }
  if ($runner) {
    $environment.runner = $runner
  }

  $runnerImage = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'runnerImageVersion')
  if ($runnerImage) {
    $environment.runnerImage = $runnerImage
  }

  $runnerOs = Get-TextValue -Value (Get-PropertyValue -Object $runContext -Name 'runnerOS')
  if (-not $runnerOs) {
    $runnerOs = Get-TextValue -Value $env:RUNNER_OS
  }
  if ($runnerOs) {
    $environment.os = $runnerOs
  }

  $pwshVersion = Get-TextValue -Value $PSVersionTable.PSVersion.ToString()
  if ($pwshVersion) {
    $environment.pwsh = $pwshVersion
  }

  $gitVersion = $null
  try {
    $gitVersion = Get-TextValue -Value ((& git --version 2>$null | Out-String).Trim())
  } catch {
    $gitVersion = $null
  }
  if ($gitVersion) {
    $environment.git = $gitVersion
  }

  $tests = $null
  if ($summary) {
    $testsSummary = [ordered]@{
      total = [int](Get-PropertyValue -Object $summary -Name 'total')
      passed = [int](Get-PropertyValue -Object $summary -Name 'passed')
      failed = [int](Get-PropertyValue -Object $summary -Name 'failed')
      errors = [int](Get-PropertyValue -Object $summary -Name 'errors')
      skipped = [int](Get-PropertyValue -Object $summary -Name 'skipped')
    }

    $durationSeconds = Get-PropertyValue -Object $summary -Name 'duration_s'
    if ($null -ne $durationSeconds) {
      $testsSummary.durationSeconds = [double]$durationSeconds
    }

    $tests = [ordered]@{
      summary = $testsSummary
    }
  }

  $artifacts = New-Object System.Collections.ArrayList
  [void]$artifacts.Add([ordered]@{
    name = 'session-index-v1'
    path = 'session-index.json'
    kind = 'summary'
  })
  [void]$artifacts.Add([ordered]@{
    name = 'session-index-v2'
    path = 'session-index-v2.json'
    kind = 'summary'
  })

  if ($files) {
    foreach ($property in $files.PSObject.Properties) {
      $artifactPath = Get-TextValue -Value $property.Value
      if (-not $artifactPath) {
        continue
      }

      [void]$artifacts.Add([ordered]@{
        name = $property.Name
        path = $artifactPath
        kind = Get-ArtifactKindForFileKey -Key $property.Name
      })
    }
  }

  $notes = New-Object System.Collections.ArrayList
  $branchProtectionPayload = $null
  if ($branchProtection) {
    $expectedContexts = Get-StringArray -Value (Get-PropertyValue -Object $branchProtection -Name 'expected')
    $hasActualBlock = Test-HasProperty -Object $branchProtection -Name 'actual'
    $actualBlock = Get-PropertyValue -Object $branchProtection -Name 'actual'
    $actualStatus = Get-TextValue -Value (Get-PropertyValue -Object $actualBlock -Name 'status')
    $actualContexts = Get-StringArray -Value (Get-PropertyValue -Object $actualBlock -Name 'contexts')
    $bpNotes = Get-StringArray -Value (Get-PropertyValue -Object $branchProtection -Name 'notes')

    if (-not $actualStatus) {
      if ($actualContexts.Count -gt 0) {
        $actualStatus = 'available'
      } else {
        # Legacy v1 payloads can omit the live branch-protection query result entirely.
        # Preserve that as unavailable instead of synthesizing green-looking live evidence.
        $actualStatus = 'unavailable'
      }
    }

    $branchProtectionStatus = Resolve-SessionIndexV2BranchProtectionStatus -Value (Get-PropertyValue -Object (Get-PropertyValue -Object $branchProtection -Name 'result') -Name 'status')
    $reason = Resolve-SessionIndexV2BranchProtectionReason -Value (Get-PropertyValue -Object (Get-PropertyValue -Object $branchProtection -Name 'result') -Name 'reason')
    $actualReason = Resolve-SessionIndexV2ActualReason -ActualStatus $actualStatus -Notes $bpNotes
    $preferActualReason = $actualReason -and (
      ($hasActualBlock -and $actualStatus -in @('error', 'unavailable')) -or
      (-not $reason) -or
      $reason -eq 'aligned'
    )
    if ($preferActualReason) {
      $reason = $actualReason
      if ($actualStatus -eq 'error') {
        $branchProtectionStatus = 'error'
      } elseif ($actualStatus -eq 'unavailable') {
        $branchProtectionStatus = 'warn'
      }
      $actualContexts = [string[]]@()
    }

    $branchProtectionPayload = [ordered]@{
      status = $branchProtectionStatus
      expected = $expectedContexts
      actual = $actualContexts
    }

    if ($reason) {
      $branchProtectionPayload.reason = $reason
    }

    $mappingPath = Get-TextValue -Value (Get-PropertyValue -Object (Get-PropertyValue -Object $branchProtection -Name 'contract') -Name 'mappingPath')
    $mappingDigest = Get-TextValue -Value (Get-PropertyValue -Object (Get-PropertyValue -Object $branchProtection -Name 'contract') -Name 'mappingDigest')
    if ($mappingPath -and $mappingDigest) {
      $branchProtectionPayload.mapping = [ordered]@{
        path = $mappingPath
        digest = $mappingDigest
      }
    }

    foreach ($note in $bpNotes) {
      Add-UniqueString -List $notes -Value $note
    }
  }

  $repositoryUrl = Get-TextValue -Value (Get-PropertyValue -Object $urls -Name 'repository')
  if ($repositoryUrl) {
    Add-UniqueString -List $notes -Value ("Repository URL: {0}" -f $repositoryUrl)
  }
  $runUrl = Get-TextValue -Value (Get-PropertyValue -Object $urls -Name 'run')
  if ($runUrl) {
    Add-UniqueString -List $notes -Value ("Run URL: {0}" -f $runUrl)
  }

  $payload = [ordered]@{
    schema = 'session-index/v2'
    schemaVersion = '1.0.0'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    run = $run
  }

  if ($environment.Count -gt 0) {
    $payload.environment = $environment
  }
  if ($branchProtectionPayload) {
    $payload.branchProtection = $branchProtectionPayload
  }
  if ($tests) {
    $payload.tests = $tests
  }
  if ($artifacts.Count -gt 0) {
    $payload.artifacts = @($artifacts)
  }
  if ($notes.Count -gt 0) {
    $payload.notes = @($notes)
  }

  return $payload
}

try {
  if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
  }
  $idxPath = Join-Path $ResultsDir 'session-index.json'
  $v2Path = Join-Path $ResultsDir 'session-index-v2.json'

  $forceV2 = $ForceSessionIndexV2.IsPresent
  $disableV2 = $DisableSessionIndexV2.IsPresent -and -not $forceV2
  if (-not $disableV2 -and -not $forceV2) {
    $envToggle = [string]$env:SESSION_INDEX_V2_EMIT
    if (-not [string]::IsNullOrWhiteSpace($envToggle)) {
      if ($envToggle.Trim().ToLowerInvariant() -in @('0', 'false', 'off', 'no')) {
        $disableV2 = $true
      }
    }
  }

  $idxExists = Test-Path -LiteralPath $idxPath -PathType Leaf
  $v2Exists = Test-Path -LiteralPath $v2Path -PathType Leaf
  if ($idxExists -and ($disableV2 -or ($v2Exists -and -not $forceV2))) { return }

  if (-not $idxExists) {
    $idx = [ordered]@{
      schema             = 'session-index/v1'
      schemaVersion      = '1.0.0'
      generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
      resultsDir         = $ResultsDir
      includeIntegration = $false
      integrationMode    = $null
      integrationSource  = $null
      files              = [ordered]@{}
    }
    $sumPath = Join-Path $ResultsDir $SummaryJson
    if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
      try {
        $s = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $includeIntegration = $false
        if ($s.PSObject.Properties.Name -contains 'includeIntegration') {
          $includeIntegration = [bool]$s.includeIntegration
        }
        $integrationMode = $null
        if ($s.PSObject.Properties.Name -contains 'integrationMode') {
          $integrationMode = $s.integrationMode
        }
        $integrationSource = $null
        if ($s.PSObject.Properties.Name -contains 'integrationSource') {
          $integrationSource = $s.integrationSource
        }
        $idx.includeIntegration = $includeIntegration
        $idx.integrationMode = $integrationMode
        $idx.integrationSource = $integrationSource
        $idx['summary'] = [ordered]@{
          total      = $s.total
          passed     = $s.passed
          failed     = $s.failed
          errors     = $s.errors
          skipped    = $s.skipped
          duration_s = $s.duration_s
          schemaVersion = $s.schemaVersion
        }
        $idx.status = if (($s.failed -gt 0) -or ($s.errors -gt 0)) { 'fail' } else { 'ok' }
        $idx.files['pesterSummaryJson'] = (Split-Path -Leaf $SummaryJson)
        # Minimal step summary
        $lines = @()
        $lines += '### Session Overview (fallback)'
        $lines += ("- Status: {0}" -f $idx.status)
        $lines += ("- Total: {0} | Passed: {1} | Failed: {2} | Errors: {3} | Skipped: {4}" -f $s.total,$s.passed,$s.failed,$s.errors,$s.skipped)
        $lines += ("- Duration (s): {0}" -f $s.duration_s)
        $lines += ("- Include Integration: {0}" -f $includeIntegration)
        if ($integrationMode) { $lines += ("- Integration Mode: {0}" -f $integrationMode) }
        if ($integrationSource) { $lines += ("- Integration Source: {0}" -f $integrationSource) }
        $idx['stepSummary'] = ($lines -join "`n")
      } catch {
        Write-Verbose ("Unable to enrich fallback session index from summary JSON: {0}" -f $_.Exception.Message)
      }
    }
    $idx | ConvertTo-Json -Depth 5 | Out-File -FilePath $idxPath -Encoding utf8
    Write-Host ("Fallback session index created at: {0}" -f $idxPath)
  }

  if (-not $disableV2 -and ((-not (Test-Path -LiteralPath $v2Path -PathType Leaf)) -or $forceV2)) {
    try {
      $sessionIndex = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
      $payload = ConvertTo-SessionIndexV2Payload -SessionIndex $sessionIndex
      $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $v2Path -Encoding UTF8
      Write-Host ("Session index v2 created at: {0}" -f $v2Path)
    } catch {
      Write-Host "::warning::Session index v2 emission failed: $_"
    }
  }
} catch {
  Write-Host "::warning::Ensure-SessionIndex failed: $_"
}
