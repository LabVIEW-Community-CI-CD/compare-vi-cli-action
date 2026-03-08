#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$EventName = '',
  [string]$Repository = '',
  [string]$PullRequestNumber = '',
  [string]$BaseSha = '',
  [string]$HeadSha = '',
  [string]$BaseRef = '',
  [string]$HeadRef = '',
  [string[]]$ChangedFile = @(),
  [string]$GitHubOutputPath = '',
  [string]$StepSummaryPath = '',
  [string]$JsonPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeLabels = @('compare-engine-history', 'docker-vi-history')
$lightweightLabels = @('docs-metadata', 'tests-only', 'tools-policy', 'ci-control-plane')

function Normalize-Path {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }

  return $Path.Trim().Replace('\', '/')
}

function New-PathMatchers {
  param([string[]]$Patterns)

  $matchers = New-Object System.Collections.Generic.List[System.Management.Automation.WildcardPattern]
  $ignoreCase = [System.Management.Automation.WildcardOptions]::IgnoreCase
  foreach ($pattern in @($Patterns)) {
    if ([string]::IsNullOrWhiteSpace($pattern)) {
      continue
    }

    $matchers.Add([System.Management.Automation.WildcardPattern]::new($pattern, $ignoreCase)) | Out-Null
  }

  return @($matchers)
}

function Test-PathAgainstMatchers {
  param(
    [System.Management.Automation.WildcardPattern[]]$Matchers,
    [string]$Path
  )

  foreach ($matcher in @($Matchers)) {
    if ($matcher.IsMatch($Path)) {
      return $true
    }
  }

  return $false
}

function Ensure-CommitAvailable {
  param([string]$Sha)

  if ([string]::IsNullOrWhiteSpace($Sha)) {
    return $false
  }

  & git cat-file -e "${Sha}^{commit}" 2>$null
  if ($LASTEXITCODE -eq 0) {
    return $true
  }

  & git fetch --no-tags --depth=1 origin $Sha 2>$null | Out-Null
  & git cat-file -e "${Sha}^{commit}" 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-PullRequestFilesFromApi {
  if ([string]::IsNullOrWhiteSpace($PullRequestNumber)) {
    return @()
  }

  $prNumber = 0
  if (-not [int]::TryParse($PullRequestNumber, [ref]$prNumber) -or $prNumber -le 0) {
    return @()
  }

  if ([string]::IsNullOrWhiteSpace($Repository)) {
    return @()
  }

  $token = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GITHUB_TOKEN
  } elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $env:GH_TOKEN
  } else {
    ''
  }
  if ([string]::IsNullOrWhiteSpace($token)) {
    return @()
  }

  $apiBase = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_API_URL)) {
    $env:GITHUB_API_URL.TrimEnd('/')
  } else {
    'https://api.github.com'
  }

  $headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $paths = New-Object System.Collections.Generic.List[string]
  $page = 1
  while ($true) {
    $uri = '{0}/repos/{1}/pulls/{2}/files?per_page=100&page={3}' -f $apiBase, $Repository, $prNumber, $page
    try {
      $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
      break
    }

    if (-not $response) {
      break
    }

    foreach ($entry in $response) {
      $filename = Normalize-Path -Path ([string]$entry.filename)
      if (-not [string]::IsNullOrWhiteSpace($filename)) {
        $paths.Add($filename) | Out-Null
      }
    }

    if ($response.Count -lt 100) {
      break
    }

    $page++
  }

  return @($paths | Sort-Object -Unique)
}

function Resolve-ChangedFilesFromRefs {
  if ([string]::IsNullOrWhiteSpace($BaseRef) -or [string]::IsNullOrWhiteSpace($HeadRef)) {
    return @()
  }

  $normalizedBaseRef = $BaseRef.Trim()
  $normalizedHeadRef = $HeadRef.Trim()
  $remoteBase = "refs/remotes/origin/$normalizedBaseRef"
  $remoteHead = "refs/remotes/origin/$normalizedHeadRef"

  $fetchBase = "+refs/heads/${normalizedBaseRef}:$remoteBase"
  $fetchHead = "+refs/heads/${normalizedHeadRef}:$remoteHead"
  & git fetch --no-tags --depth=200 origin $fetchBase 2>$null | Out-Null
  & git fetch --no-tags --depth=200 origin $fetchHead 2>$null | Out-Null

  $baseReady = (& git rev-parse --verify $remoteBase 2>$null | Select-Object -First 1)
  $headReady = (& git rev-parse --verify $remoteHead 2>$null | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($baseReady) -or [string]::IsNullOrWhiteSpace($headReady)) {
    return @()
  }

  $rangeFiles = & git diff --name-only --diff-filter=ACMRTUXB "$remoteBase..$remoteHead" 2>$null
  return @(
    $rangeFiles |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { Normalize-Path -Path $_ } |
      Sort-Object -Unique
  )
}

function Resolve-ChangedFilesFromShas {
  if ([string]::IsNullOrWhiteSpace($BaseSha) -or [string]::IsNullOrWhiteSpace($HeadSha)) {
    return @()
  }

  $baseReady = Ensure-CommitAvailable -Sha $BaseSha
  $headReady = Ensure-CommitAvailable -Sha $HeadSha
  if (-not $baseReady -or -not $headReady) {
    return @()
  }

  $rangeFiles = & git diff --name-only --diff-filter=ACMRTUXB "$BaseSha..$HeadSha" 2>$null
  return @(
    $rangeFiles |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { Normalize-Path -Path $_ } |
      Sort-Object -Unique
  )
}

function Resolve-ChangedFilesFromPullRequestMergeCommit {
  $firstParent = (& git rev-parse --verify HEAD^1 2>$null | Select-Object -First 1)
  $secondParent = (& git rev-parse --verify HEAD^2 2>$null | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($firstParent) -or [string]::IsNullOrWhiteSpace($secondParent)) {
    return @()
  }

  $rangeFiles = & git diff --name-only --diff-filter=ACMRTUXB 'HEAD^1..HEAD' 2>$null
  return @(
    $rangeFiles |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { Normalize-Path -Path $_ } |
      Sort-Object -Unique
  )
}

function Resolve-ChangedFilesFromWorkingTree {
  $paths = New-Object System.Collections.Generic.List[string]
  $worktreeFiles = & git diff --name-only --diff-filter=ACMRTUXB HEAD 2>$null
  foreach ($path in @($worktreeFiles)) {
    $normalized = Normalize-Path -Path $path
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
      $paths.Add($normalized) | Out-Null
    }
  }

  $stagedFiles = & git diff --name-only --cached --diff-filter=ACMRTUXB 2>$null
  foreach ($path in @($stagedFiles)) {
    $normalized = Normalize-Path -Path $path
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
      $paths.Add($normalized) | Out-Null
    }
  }

  return @($paths | Sort-Object -Unique)
}

function Resolve-ChangedFiles {
  $paths = New-Object System.Collections.Generic.List[string]

  foreach ($item in @($ChangedFile)) {
    $normalized = Normalize-Path -Path $item
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
      $paths.Add($normalized) | Out-Null
    }
  }

  if ($paths.Count -eq 0 -and $EventName -eq 'pull_request') {
    foreach ($item in @(Resolve-PullRequestFilesFromApi)) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        $paths.Add($item) | Out-Null
      }
    }
  }

  if ($paths.Count -eq 0 -and $EventName -eq 'pull_request') {
    foreach ($item in @(Resolve-ChangedFilesFromRefs)) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        $paths.Add($item) | Out-Null
      }
    }
  }

  if ($paths.Count -eq 0 -and ($EventName -eq 'pull_request' -or $EventName -eq 'merge_group')) {
    foreach ($item in @(Resolve-ChangedFilesFromShas)) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        $paths.Add($item) | Out-Null
      }
    }
  }

  if ($paths.Count -eq 0 -and $EventName -eq 'pull_request') {
    foreach ($item in @(Resolve-ChangedFilesFromPullRequestMergeCommit)) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        $paths.Add($item) | Out-Null
      }
    }
  }

  if ($paths.Count -eq 0 -and -not $env:GITHUB_ACTIONS) {
    foreach ($item in @(Resolve-ChangedFilesFromWorkingTree)) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        $paths.Add($item) | Out-Null
      }
    }
  }

  return @($paths | Sort-Object -Unique)
}

function New-ScopeDefinitions {
  return @(
    [pscustomobject]@{
      Label    = 'docker-vi-history'
      Matchers = New-PathMatchers -Patterns @(
        'docker/*',
        'scripts/Dispatch-VIHistoryWorkflow.ps1',
        'scripts/Run-VIHistory.ps1',
        'tools/Assert-DockerRuntimeDeterminism.ps1',
        'tools/Dispatch-WithSample.ps1',
        'tools/Invoke-DockerRuntimeManager.ps1',
        'tools/Resolve-ValidateVIHistoryDispatchPlan.ps1',
        'tools/Run-NILinuxContainerCompare.ps1',
        'tools/Run-NIWindowsContainerCompare.ps1',
        'tools/Test-DockerDesktopFastLoop.ps1',
        'tools/Test-PRVIHistorySmoke.ps1',
        'tools/Write-DockerFastLoopProof.ps1',
        'tools/Write-DockerFastLoopReadiness.ps1',
        'tools/Write-VIHistoryBenchmark.ps1',
        'tools/Write-VIHistoryWorkflowReadiness.ps1'
      )
    }
    [pscustomobject]@{
      Label    = 'compare-engine-history'
      Matchers = New-PathMatchers -Patterns @(
        'action.yml',
        'fixtures/*',
        'scripts/*',
        'src/*',
        'tools/Compare-*',
        'tools/CompareVI.Tools/*',
        'tools/Get-VICompareMetadata.ps1',
        'tools/Invoke-CompareCli.ps1',
        'tools/Publish-CompareVIToolsArtifact.ps1',
        'tools/Test-CompareVIHistoryBundleCertification.ps1',
        'docs/schemas/comparevi-*',
        'docs/schemas/fixture-*'
      )
    }
    [pscustomobject]@{
      Label    = 'ci-control-plane'
      Matchers = New-PathMatchers -Patterns @(
        '.github/actions/*',
        '.github/workflows/*',
        'tools/workflows/*'
      )
    }
    [pscustomobject]@{
      Label    = 'tools-policy'
      Matchers = New-PathMatchers -Patterns @(
        'tools/Assert-LineEndingDeterminism.ps1',
        'tools/Assert-ValidateOutputs.ps1',
        'tools/Check-*',
        'tools/Get-BranchProtectionRequiredChecks.ps1',
        'tools/hooks/*',
        'tools/Lint-*',
        'tools/PrePush-Checks.ps1',
        'tools/priority/*',
        'tools/policy/*',
        'tools/Quick-DispatcherSmoke.ps1',
        'tools/Resolve-ValidateScopePlan.ps1',
        'tools/Test-SessionIndexV2Contract.ps1',
        'tools/Update-SessionIndex*.ps1',
        'tools/Write-RunProvenance.ps1'
      )
    }
    [pscustomobject]@{
      Label    = 'tests-only'
      Matchers = New-PathMatchers -Patterns @(
        'tests/*',
        'tools/hooks/__tests__/*',
        'tools/priority/__tests__/*'
      )
    }
    [pscustomobject]@{
      Label    = 'docs-metadata'
      Matchers = New-PathMatchers -Patterns @(
        '*.code-workspace',
        '*.md',
        '.github/*.md',
        '.github/ISSUE_TEMPLATE/*',
        '.gitignore',
        '.gitattributes',
        '.openai-ignore',
        '.vscode/*',
        'AGENTS.md',
        'docs/*',
        'LICENSE'
      )
    }
  )
}

function Get-PathLabel {
  param(
    [string]$Path,
    [pscustomobject[]]$Definitions
  )

  foreach ($definition in @($Definitions)) {
    if (Test-PathAgainstMatchers -Matchers $definition.Matchers -Path $Path) {
      return $definition.Label
    }
  }

  return 'unclassified'
}

function New-LaneDecision {
  param(
    [bool]$Run,
    [string]$Reason
  )

  return [ordered]@{
    run    = [bool]$Run
    reason = $Reason
  }
}

function Build-ScopePlan {
  $definitions = New-ScopeDefinitions
  $changedFiles = @(Resolve-ChangedFiles)
  $classifiedPaths = @()
  $distinctLabels = @()
  $unclassifiedPaths = @()
  $pullRequestNumberValue = $null

  foreach ($path in @($changedFiles)) {
    $label = Get-PathLabel -Path $path -Definitions $definitions
    $classifiedPaths += [pscustomobject]@{
      path  = $path
      label = $label
    }
    if ($distinctLabels -notcontains $label) {
      $distinctLabels += $label
    }
    if ($label -eq 'unclassified') {
      $unclassifiedPaths += $path
    }
  }

  $runtimeLabelsPresent = @($distinctLabels | Where-Object { $runtimeLabels -contains $_ })
  $lightweightLabelsPresent = @($distinctLabels | Where-Object { $lightweightLabels -contains $_ })

  if (-not [string]::IsNullOrWhiteSpace($PullRequestNumber)) {
    $pullRequestNumberValue = $PullRequestNumber
  }

  $scopeMode = 'scoped'
  $scopeCategory = ''
  $lanes = [ordered]@{}

  if ($EventName -eq 'workflow_dispatch') {
    $scopeMode = 'manual'
    $scopeCategory = 'manual-full'
    $lanes.fixtures = New-LaneDecision -Run $true -Reason 'workflow-dispatch-explicit'
    $lanes.bundleCertification = New-LaneDecision -Run $true -Reason 'workflow-dispatch-explicit'
    $lanes.viHistory = New-LaneDecision -Run $true -Reason 'workflow-dispatch-explicit'
  } elseif ($EventName -eq 'push') {
    $scopeMode = 'push'
    $scopeCategory = 'push-full'
    $lanes.fixtures = New-LaneDecision -Run $true -Reason 'push-default-full'
    $lanes.bundleCertification = New-LaneDecision -Run $true -Reason 'push-default-full'
    $lanes.viHistory = New-LaneDecision -Run $false -Reason 'push-default-no-vi-history'
  } elseif ($changedFiles.Count -eq 0) {
    $scopeCategory = 'unclassified'
    $lanes.fixtures = New-LaneDecision -Run $true -Reason 'empty-change-set'
    $lanes.bundleCertification = New-LaneDecision -Run $true -Reason 'empty-change-set'
    $lanes.viHistory = New-LaneDecision -Run $true -Reason 'empty-change-set'
  } elseif ($unclassifiedPaths.Count -gt 0) {
    $scopeCategory = 'unclassified'
    $lanes.fixtures = New-LaneDecision -Run $true -Reason 'unclassified-paths'
    $lanes.bundleCertification = New-LaneDecision -Run $true -Reason 'unclassified-paths'
    $lanes.viHistory = New-LaneDecision -Run $true -Reason 'unclassified-paths'
  } elseif ($runtimeLabelsPresent.Count -eq 0) {
    if ($distinctLabels.Count -eq 1 -and $distinctLabels[0] -eq 'docs-metadata') {
      $scopeCategory = 'docs-metadata-only'
      $reason = 'docs-metadata-only'
    } elseif ($distinctLabels.Count -eq 1 -and $distinctLabels[0] -eq 'tests-only') {
      $scopeCategory = 'tests-only'
      $reason = 'tests-only'
    } elseif (@($distinctLabels | Where-Object { $_ -eq 'tools-policy' }).Count -gt 0 -and @($distinctLabels | Where-Object { $_ -eq 'ci-control-plane' }).Count -eq 0) {
      $scopeCategory = 'tools-policy-only'
      $reason = 'tools-policy-only'
    } else {
      $scopeCategory = 'ci-control-plane'
      $reason = 'ci-control-plane-only'
    }

    $lanes.fixtures = New-LaneDecision -Run $false -Reason $reason
    $lanes.bundleCertification = New-LaneDecision -Run $false -Reason $reason
    $lanes.viHistory = New-LaneDecision -Run $false -Reason $reason
  } elseif ($runtimeLabelsPresent.Count -eq 1 -and $runtimeLabelsPresent[0] -eq 'docker-vi-history') {
    $scopeCategory = 'docker-vi-history'
    $lanes.fixtures = New-LaneDecision -Run $false -Reason 'docker-vi-history-scope'
    $lanes.bundleCertification = New-LaneDecision -Run $false -Reason 'docker-vi-history-scope'
    $lanes.viHistory = New-LaneDecision -Run $true -Reason 'docker-vi-history-scope'
  } elseif ($runtimeLabelsPresent.Count -eq 1 -and $runtimeLabelsPresent[0] -eq 'compare-engine-history') {
    $scopeCategory = 'compare-engine-history'
    $lanes.fixtures = New-LaneDecision -Run $true -Reason 'compare-engine-history-scope'
    $lanes.bundleCertification = New-LaneDecision -Run $true -Reason 'compare-engine-history-scope'
    $lanes.viHistory = New-LaneDecision -Run $true -Reason 'compare-engine-history-scope'
  } else {
    $scopeCategory = 'mixed-runtime'
    $lanes.fixtures = New-LaneDecision -Run $true -Reason 'mixed-runtime-scope'
    $lanes.bundleCertification = New-LaneDecision -Run $true -Reason 'mixed-runtime-scope'
    $lanes.viHistory = New-LaneDecision -Run $true -Reason 'mixed-runtime-scope'
  }

  return [ordered]@{
    schema             = 'validate-scope-plan@v1'
    generatedAt        = (Get-Date).ToUniversalTime().ToString('o')
    eventName          = $EventName
    repository         = $Repository
    pullRequestNumber  = $pullRequestNumberValue
    scopeMode          = $scopeMode
    scopeCategory      = $scopeCategory
    changedFileCount   = $changedFiles.Count
    changedFiles       = @($changedFiles)
    classifiedPaths    = @($classifiedPaths)
    classifications    = [ordered]@{
      labels             = @($distinctLabels)
      runtimeLabels      = @($runtimeLabelsPresent)
      lightweightLabels  = @($lightweightLabelsPresent)
      unclassifiedPaths  = @($unclassifiedPaths)
    }
    lanes              = [ordered]@{
      fixtures            = $lanes.fixtures
      bundleCertification = $lanes.bundleCertification
      viHistory           = $lanes.viHistory
    }
  }
}

$plan = Build-ScopePlan

if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
  $jsonDir = Split-Path -Parent $JsonPath
  if ($jsonDir -and -not (Test-Path -LiteralPath $jsonDir -PathType Container)) {
    New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
  }
  $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JsonPath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  "scope_mode=$($plan.scopeMode)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "scope_category=$($plan.scopeCategory)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "changed_files_count=$($plan.changedFileCount)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "run_fixtures=$($plan.lanes.fixtures.run.ToString().ToLowerInvariant())" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "fixtures_reason=$($plan.lanes.fixtures.reason)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "run_bundle_certification=$($plan.lanes.bundleCertification.run.ToString().ToLowerInvariant())" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "bundle_certification_reason=$($plan.lanes.bundleCertification.reason)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "run_vi_history=$($plan.lanes.viHistory.run.ToString().ToLowerInvariant())" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "vi_history_reason=$($plan.lanes.viHistory.reason)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "has_unclassified_paths=$(([bool]($plan.classifications.unclassifiedPaths.Count -gt 0)).ToString().ToLowerInvariant())" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $lines = @(
    '### Validate Scope Plan',
    '',
    ('- scope_mode: `{0}`' -f $plan.scopeMode),
    ('- scope_category: `{0}`' -f $plan.scopeCategory),
    ('- changed_files: `{0}`' -f $plan.changedFileCount),
    ('- fixtures: `{0}` (`{1}`)' -f $plan.lanes.fixtures.run.ToString().ToLowerInvariant(), $plan.lanes.fixtures.reason),
    ('- bundle_certification: `{0}` (`{1}`)' -f $plan.lanes.bundleCertification.run.ToString().ToLowerInvariant(), $plan.lanes.bundleCertification.reason),
    ('- vi_history: `{0}` (`{1}`)' -f $plan.lanes.viHistory.run.ToString().ToLowerInvariant(), $plan.lanes.viHistory.reason)
  )

  if ($plan.changedFileCount -gt 0) {
    $lines += ''
    $lines += 'Changed path sample:'
    foreach ($entry in @($plan.classifiedPaths | Select-Object -First 15)) {
      $lines += ('- `{0}` -> `{1}`' -f $entry.path, $entry.label)
    }
  }

  if ($plan.classifications.unclassifiedPaths.Count -gt 0) {
    $lines += ''
    $lines += 'Unclassified paths:'
    foreach ($path in @($plan.classifications.unclassifiedPaths | Select-Object -First 15)) {
      $lines += ('- `{0}`' -f $path)
    }
  }

  $lines -join "`n" | Out-File -FilePath $StepSummaryPath -Append -Encoding utf8
}

$plan | ConvertTo-Json -Depth 10
