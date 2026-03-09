Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GitHubIntakeRepoRoot {
  Split-Path -Parent $PSScriptRoot
}

function Get-GitHubIntakeCatalogPath {
  $override = [Environment]::GetEnvironmentVariable('COMPAREVI_GITHUB_INTAKE_CATALOG_PATH')
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    return $override
  }

  Join-Path (Get-GitHubIntakeRepoRoot) 'tools' 'priority' 'github-intake-catalog.json'
}

function Read-GitHubIntakeJsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Get-GitHubIssueSnapshotDirectory {
  $override = [Environment]::GetEnvironmentVariable('COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR')
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    return $override
  }

  Join-Path (Get-GitHubIntakeRepoRoot) 'tests' 'results' '_agent' 'issue'
}

function Get-GitHubIntakeCatalog {
  $catalogPath = Get-GitHubIntakeCatalogPath
  if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "GitHub intake catalog not found: $catalogPath"
  }

  Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -ErrorAction Stop
}

function Get-SupportedGitHubIssueTemplates {
  @((Get-GitHubIntakeCatalog).issueTemplates | ForEach-Object { [string]$_.key })
}

function Get-SupportedGitHubPullRequestTemplates {
  @((Get-GitHubIntakeCatalog).pullRequestTemplates | ForEach-Object { [string]$_.key })
}

function Get-GitHubIntakeScenarios {
  @((Get-GitHubIntakeCatalog).routes | ForEach-Object { [string]$_.scenario })
}

function Resolve-GitHubIssueSnapshot {
  param([int]$Issue)

  $issueDir = Get-GitHubIssueSnapshotDirectory
  if (-not (Test-Path -LiteralPath $issueDir -PathType Container)) {
    return $null
  }

  if ($Issue -gt 0) {
    $snapshot = Read-GitHubIntakeJsonFile -Path (Join-Path $issueDir ("{0}.json" -f $Issue))
    if ($snapshot) {
      return $snapshot
    }
  }

  $router = Read-GitHubIntakeJsonFile -Path (Join-Path $issueDir 'router.json')
  if ($router -and ($router.PSObject.Properties.Name -contains 'issue')) {
    [int]$routerIssue = 0
    if ([int]::TryParse([string]$router.issue, [ref]$routerIssue) -and $routerIssue -gt 0) {
      $snapshot = Read-GitHubIntakeJsonFile -Path (Join-Path $issueDir ("{0}.json" -f $routerIssue))
      if ($snapshot) {
        return $snapshot
      }
    }
  }

  $latest = Get-ChildItem -LiteralPath $issueDir -Filter '*.json' |
    Where-Object { $_.BaseName -match '^\d+$' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $latest) {
    return $null
  }

  Read-GitHubIntakeJsonFile -Path $latest.FullName
}

function Resolve-GitHubIssueTemplate {
  param(
    [string]$TemplateName,
    [pscustomobject]$Catalog
  )

  if ([string]::IsNullOrWhiteSpace($TemplateName)) {
    throw 'Issue template name is required.'
  }

  if (-not $Catalog) {
    $Catalog = Get-GitHubIntakeCatalog
  }

  $template = $Catalog.issueTemplates | Where-Object { [string]$_.key -eq $TemplateName } | Select-Object -First 1
  if (-not $template) {
    $supported = (Get-SupportedGitHubIssueTemplates) -join ', '
    throw "Unsupported issue template '$TemplateName'. Supported templates: $supported"
  }

  return $template
}

function Resolve-GitHubPullRequestTemplate {
  param(
    [string]$TemplateName,
    [pscustomobject]$Catalog
  )

  if ([string]::IsNullOrWhiteSpace($TemplateName)) {
    throw 'Pull request template name is required.'
  }

  if (-not $Catalog) {
    $Catalog = Get-GitHubIntakeCatalog
  }

  $template = $Catalog.pullRequestTemplates | Where-Object { [string]$_.key -eq $TemplateName } | Select-Object -First 1
  if (-not $template) {
    $supported = (Get-SupportedGitHubPullRequestTemplates) -join ', '
    throw "Unsupported pull request template '$TemplateName'. Supported templates: $supported"
  }

  return $template
}

function Resolve-GitHubIntakeRoute {
  param(
    [string]$Scenario,
    [pscustomobject]$Catalog
  )

  if ([string]::IsNullOrWhiteSpace($Scenario)) {
    throw 'Intake scenario is required.'
  }

  if (-not $Catalog) {
    $Catalog = Get-GitHubIntakeCatalog
  }

  $route = $Catalog.routes | Where-Object { [string]$_.scenario -eq $Scenario } | Select-Object -First 1
  if (-not $route) {
    $supported = (Get-GitHubIntakeScenarios) -join ', '
    throw "Unsupported intake scenario '$Scenario'. Supported scenarios: $supported"
  }

  $targetName = $null
  $targetPath = $null
  $targetUrl = $null

  switch ([string]$route.routeType) {
    'issue-template' {
      $target = Resolve-GitHubIssueTemplate -TemplateName ([string]$route.targetKey) -Catalog $Catalog
      $targetName = [string]$target.name
      $targetPath = [string]$target.path
    }
    'pull-request-template' {
      $target = Resolve-GitHubPullRequestTemplate -TemplateName ([string]$route.targetKey) -Catalog $Catalog
      $targetName = [string]$target.templateLabel
      $targetPath = [string]$target.path
    }
    'contact-link' {
      $target = $Catalog.contactLinks | Where-Object { [string]$_.name -eq [string]$route.targetKey } | Select-Object -First 1
      if (-not $target) {
        throw "Contact link '$($route.targetKey)' not found in GitHub intake catalog."
      }

      $targetName = [string]$target.name
      $targetUrl = [string]$target.url
    }
    default {
      throw "Unsupported GitHub intake route type '$($route.routeType)'."
    }
  }

  [pscustomobject]@{
    scenario   = [string]$route.scenario
    routeType  = [string]$route.routeType
    targetKey  = [string]$route.targetKey
    targetName = $targetName
    targetPath = $targetPath
    targetUrl  = $targetUrl
    helperPath = [string]$route.helperPath
    command    = [string]$route.command
    executeCommand = if ($route.PSObject.Properties.Name -contains 'executeCommand') { [string]$route.executeCommand } else { $null }
    summary    = [string]$route.summary
  }
}

function Resolve-GitHubIntakeDraftContext {
  param(
    [string]$Scenario,
    [int]$Issue,
    [string]$IssueTitle,
    [string]$IssueUrl,
    [string]$Branch,
    [bool]$StandingPriority = $false,
    [string]$CurrentBranch
  )

  $route = Resolve-GitHubIntakeRoute -Scenario $Scenario
  $resolvedIssue = $Issue
  $resolvedIssueTitle = $IssueTitle
  $resolvedIssueUrl = $IssueUrl
  $resolvedBranch = $Branch
  $resolvedStandingPriority = $StandingPriority
  $snapshotResolved = $false

  if ([string]$route.routeType -eq 'pull-request-template') {
    $snapshot = Resolve-GitHubIssueSnapshot -Issue $Issue
    if ($snapshot) {
      $snapshotResolved = $true

      if ($resolvedIssue -le 0 -and ($snapshot.PSObject.Properties.Name -contains 'number')) {
        $resolvedIssue = [int]$snapshot.number
      }

      if ([string]::IsNullOrWhiteSpace($resolvedIssueTitle) -and ($snapshot.PSObject.Properties.Name -contains 'title')) {
        $resolvedIssueTitle = [string]$snapshot.title
      }

      if ([string]::IsNullOrWhiteSpace($resolvedIssueUrl) -and ($snapshot.PSObject.Properties.Name -contains 'url')) {
        $resolvedIssueUrl = [string]$snapshot.url
      }

      if (-not $resolvedStandingPriority -and ($snapshot.PSObject.Properties.Name -contains 'labels')) {
        $resolvedStandingPriority = @($snapshot.labels) -contains 'standing-priority'
      }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedBranch) -and -not [string]::IsNullOrWhiteSpace($CurrentBranch)) {
      $resolvedBranch = $CurrentBranch
    }
  }

  [pscustomobject]@{
    scenario           = [string]$route.scenario
    routeType          = [string]$route.routeType
    templateKey        = [string]$route.targetKey
    helperPath         = [string]$route.helperPath
    command            = [string]$route.command
    executeCommand     = if ($route.PSObject.Properties.Name -contains 'executeCommand') { $route.executeCommand } else { $null }
    issue              = $resolvedIssue
    issueTitle         = $resolvedIssueTitle
    issueUrl           = $resolvedIssueUrl
    branch             = $resolvedBranch
    standingPriority   = $resolvedStandingPriority
    snapshotResolved   = $snapshotResolved
  }
}

function New-GitHubIntakeAtlasReport {
  param(
    [pscustomobject]$Catalog,
    [string]$GeneratedAtUtc
  )

  if (-not $Catalog) {
    $Catalog = Get-GitHubIntakeCatalog
  }

  if ([string]::IsNullOrWhiteSpace($GeneratedAtUtc)) {
    $GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
  }

  $routes = @($Catalog.routes | ForEach-Object { Resolve-GitHubIntakeRoute -Scenario ([string]$_.scenario) -Catalog $Catalog })

  [pscustomobject]@{
    schema               = 'github-intake/atlas@v1'
    generatedAtUtc       = $GeneratedAtUtc
    repository           = [string]$Catalog.repository
    catalogPath          = 'tools/priority/github-intake-catalog.json'
    counts               = [pscustomobject]@{
      issueTemplates       = @($Catalog.issueTemplates).Count
      pullRequestTemplates = @($Catalog.pullRequestTemplates).Count
      contactLinks         = @($Catalog.contactLinks).Count
      scenarios            = @($routes).Count
    }
    issueTemplates       = @($Catalog.issueTemplates)
    pullRequestTemplates = @($Catalog.pullRequestTemplates)
    contactLinks         = @($Catalog.contactLinks)
    routes               = $routes
  }
}

function ConvertTo-GitHubIntakeAtlasMarkdown {
  param([pscustomobject]$Report)

  if (-not $Report) {
    throw 'GitHub intake atlas report is required.'
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add('# GitHub Intake Atlas')
  $lines.Add('')
  $lines.Add(('- Generated at: `{0}`' -f [string]$Report.generatedAtUtc))
  $lines.Add(('- Repository: `{0}`' -f [string]$Report.repository))
  $lines.Add(('- Catalog: `{0}`' -f [string]$Report.catalogPath))
  $lines.Add('')
  $lines.Add('## Summary')
  $lines.Add('')
  $lines.Add('| Surface | Count |')
  $lines.Add('| --- | ---: |')
  $lines.Add(('| Issue templates | {0} |' -f $Report.counts.issueTemplates))
  $lines.Add(('| PR templates | {0} |' -f $Report.counts.pullRequestTemplates))
  $lines.Add(('| Contact links | {0} |' -f $Report.counts.contactLinks))
  $lines.Add(('| Scenario routes | {0} |' -f $Report.counts.scenarios))
  $lines.Add('')
  $lines.Add('## Issue Templates')
  $lines.Add('')
  $lines.Add('| Key | Title | Labels | Path | Summary |')
  $lines.Add('| --- | --- | --- | --- | --- |')
  foreach ($entry in @($Report.issueTemplates)) {
    $labels = @($entry.labels) -join ', '
    $lines.Add(('| {0} | {1} | {2} | `{3}` | {4} |' -f $entry.key, $entry.name, $labels, $entry.path, $entry.summary))
  }

  $lines.Add('')
  $lines.Add('## PR Templates')
  $lines.Add('')
  $lines.Add('| Key | Metadata | Path | Summary |')
  $lines.Add('| --- | --- | --- | --- |')
  foreach ($entry in @($Report.pullRequestTemplates)) {
    $lines.Add(('| {0} | {1} | `{2}` | {3} |' -f $entry.key, $entry.metadataMode, $entry.path, $entry.summary))
  }

  $lines.Add('')
  $lines.Add('## Scenario Routes')
  $lines.Add('')
  $lines.Add('| Scenario | Route Type | Target | Helper | Draft Command | Execute Command |')
  $lines.Add('| --- | --- | --- | --- | --- | --- |')
  foreach ($route in @($Report.routes)) {
    $executeCommand = if ([string]::IsNullOrWhiteSpace([string]$route.executeCommand)) { '(none)' } else { [string]$route.executeCommand }
    $lines.Add(('| {0} | {1} | `{2}` | `{3}` | `{4}` | `{5}` |' -f $route.scenario, $route.routeType, $route.targetKey, $route.helperPath, $route.command, $executeCommand))
  }

  $lines.Add('')
  $lines.Add('## Contact Links')
  $lines.Add('')
  $lines.Add('| Name | URL | About |')
  $lines.Add('| --- | --- | --- |')
  foreach ($entry in @($Report.contactLinks)) {
    $lines.Add(('| {0} | {1} | {2} |' -f $entry.name, $entry.url, $entry.about))
  }

  $lines.Add('')
  $lines.Add('## Notes')
  $lines.Add('')
  $lines.Add('- Use `Resolve-GitHubIntakeRoute.ps1` to inspect one scenario at a time.')
  $lines.Add('- Use `New-GitHubIntakeDraft.ps1` to render the correct issue or PR body from the scenario catalog.')
  $lines.Add('- Repo docs remain authoritative; the GitHub wiki is a curated navigation portal only.')

  return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Normalize-IntakeTitle {
  param([string]$Title)

  if ([string]::IsNullOrWhiteSpace($Title)) {
    return $null
  }

  $candidate = $Title.Trim()
  $candidate = $candidate -replace '^\s*\[p\d+\]\s*', ''
  $candidate = $candidate -replace '^\s*epic\s*:\s*', ''
  $candidate = $candidate.Trim()
  if (-not $candidate) {
    return $null
  }

  $first = $candidate.Substring(0, 1).ToUpperInvariant()
  if ($candidate.Length -eq 1) {
    return $first
  }

  return $first + $candidate.Substring(1)
}

function ConvertTo-IntakeSlug {
  param(
    [string]$Title,
    [string]$Fallback = 'work'
  )

  $normalized = Normalize-IntakeTitle -Title $Title
  if (-not $normalized) {
    $normalized = $Fallback
  }

  $slug = ($normalized -replace '[^a-zA-Z0-9\- ]', '' -replace '\s+', '-').ToLowerInvariant().Trim('-')
  if (-not $slug) {
    return $Fallback
  }

  return $slug
}

function Resolve-IssueBranchName {
  param(
    [int]$Number,
    [string]$Title,
    [string]$BranchPrefix = 'issue',
    [string]$CurrentBranch
  )

  if ($Number -gt 0 -and -not [string]::IsNullOrWhiteSpace($CurrentBranch)) {
    $pattern = '^{0}/{1}(?:-|$)' -f [regex]::Escape($BranchPrefix), $Number
    if ($CurrentBranch -match $pattern) {
      return $CurrentBranch
    }
  }

  $slug = ConvertTo-IntakeSlug -Title $Title
  return '{0}/{1}-{2}' -f $BranchPrefix, $Number, $slug
}

function Get-BranchHeadCommitSubject {
  param([string]$Base)

  if ([string]::IsNullOrWhiteSpace($Base)) {
    return $null
  }

  try {
    $range = "origin/$Base..HEAD"
    $countText = (& git rev-list --count $range 2>$null).Trim()
    $commitCount = 0
    if (-not [int]::TryParse($countText, [ref]$commitCount) -or $commitCount -le 0) {
      return $null
    }

    $subject = (& git log '--format=%s' '-n' '1' 'HEAD' 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($subject)) {
      return $null
    }

    return $subject.Trim()
  } catch {
    return $null
  }
}

function Resolve-PullRequestTitle {
  param(
    [int]$Issue,
    [string]$IssueTitle,
    [string]$Base
  )

  $candidate = Normalize-IntakeTitle -Title $IssueTitle
  if (-not $candidate) {
    $candidate = Get-BranchHeadCommitSubject -Base $Base
  }
  if (-not $candidate) {
    $candidate = if ($Issue -gt 0) { "Update for issue #$Issue" } else { 'Update branch' }
  }

  if ($Issue -gt 0 -and $candidate -notmatch "(?<!\d)#$Issue(?!\d)") {
    return "$candidate (#$Issue)"
  }

  return $candidate
}

Export-ModuleMember -Function `
  ConvertTo-GitHubIntakeAtlasMarkdown, `
  Get-GitHubIntakeCatalog, `
  Get-GitHubIntakeCatalogPath, `
  Get-GitHubIntakeScenarios, `
  Get-SupportedGitHubIssueTemplates, `
  Get-SupportedGitHubPullRequestTemplates, `
  New-GitHubIntakeAtlasReport, `
  Resolve-GitHubIntakeDraftContext, `
  Resolve-GitHubIssueSnapshot, `
  Resolve-GitHubIssueTemplate, `
  Resolve-GitHubPullRequestTemplate, `
  Resolve-GitHubIntakeRoute, `
  Resolve-IssueBranchName, `
  Resolve-PullRequestTitle
