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

function Normalize-GitHubIntakeExecutionKind {
  param([string]$Kind)

  switch ([string]$Kind) {
    'gh-pr-create' { return 'priority-pr-create' }
    default { return $Kind }
  }
}

function Resolve-GitHubIntakeExecutionMetadata {
  param([pscustomobject]$Route)

  if (-not $Route -or -not ($Route.PSObject.Properties.Name -contains 'execution') -or -not $Route.execution) {
    return $null
  }

  [pscustomobject]@{
    kind                = Normalize-GitHubIntakeExecutionKind -Kind ([string]$Route.execution.kind)
    titleSource         = if ($Route.execution.PSObject.Properties.Name -contains 'titleSource') { [string]$Route.execution.titleSource } else { $null }
    bodySource          = if ($Route.execution.PSObject.Properties.Name -contains 'bodySource') { [string]$Route.execution.bodySource } else { $null }
    labelSource         = if ($Route.execution.PSObject.Properties.Name -contains 'labelSource') { [string]$Route.execution.labelSource } else { $null }
    baseSource          = if ($Route.execution.PSObject.Properties.Name -contains 'baseSource') { [string]$Route.execution.baseSource } else { $null }
    branchSource        = if ($Route.execution.PSObject.Properties.Name -contains 'branchSource') { [string]$Route.execution.branchSource } else { $null }
    issueSource         = if ($Route.execution.PSObject.Properties.Name -contains 'issueSource') { [string]$Route.execution.issueSource } else { $null }
    pullRequestTemplate = if ($Route.execution.PSObject.Properties.Name -contains 'pullRequestTemplate') { [string]$Route.execution.pullRequestTemplate } else { $null }
    urlSource           = if ($Route.execution.PSObject.Properties.Name -contains 'urlSource') { [string]$Route.execution.urlSource } else { $null }
  }
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

  $execution = Resolve-GitHubIntakeExecutionMetadata -Route $route

  [pscustomobject]@{
    scenario       = [string]$route.scenario
    routeType      = [string]$route.routeType
    targetKey      = [string]$route.targetKey
    targetName     = $targetName
    targetPath     = $targetPath
    targetUrl      = $targetUrl
    helperPath     = [string]$route.helperPath
    command        = [string]$route.command
    executeCommand = if ($route.PSObject.Properties.Name -contains 'executeCommand') { [string]$route.executeCommand } else { $null }
    execution      = $execution
    executionKind  = if ($execution) { [string]$execution.kind } else { $null }
    summary        = [string]$route.summary
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
    execution          = $route.execution
    executionKind      = $route.executionKind
    issue              = $resolvedIssue
    issueTitle         = $resolvedIssueTitle
    issueUrl           = $resolvedIssueUrl
    branch             = $resolvedBranch
    standingPriority   = $resolvedStandingPriority
    snapshotResolved   = $snapshotResolved
  }
}

function Resolve-GitHubIntakeDraftOutputPath {
  param(
    [string]$RouteType,
    [string]$OutputPath
  )

  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    return $OutputPath
  }

  switch ([string]$RouteType) {
    'issue-template' { return 'issue-body.md' }
    'pull-request-template' { return 'pr-body.md' }
    default { return 'intake-body.md' }
  }
}

function Format-GitHubIntakeCommandLine {
  param(
    [string]$Command,
    [string[]]$Arguments
  )

  $parts = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($Command)) {
    $parts.Add($Command)
  }

  foreach ($argument in @($Arguments)) {
    if ($null -eq $argument) {
      continue
    }

    $text = [string]$argument
    if ($text -match '[\s'']|"') {
      $escaped = $text -replace "'", "''"
      $parts.Add(("'{0}'" -f $escaped))
    } else {
      $parts.Add($text)
    }
  }

  return ($parts -join ' ').Trim()
}

function New-GitHubIntakeExecutionPlan {
  param(
    [string]$Scenario,
    [string]$Title,
    [int]$Issue,
    [string]$IssueTitle,
    [string]$IssueUrl,
    [string]$Base = 'develop',
    [string]$Branch,
    [bool]$StandingPriority = $false,
    [string]$RelatedIssues,
    [string]$RepositoryContext = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    [string]$DraftOutputPath,
    [string]$CurrentBranch,
    [string]$GeneratedAtUtc
  )

  if ([string]::IsNullOrWhiteSpace($Scenario)) {
    throw 'Scenario is required for GitHub intake execution planning.'
  }

  if ([string]::IsNullOrWhiteSpace($GeneratedAtUtc)) {
    $GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
  }

  $route = Resolve-GitHubIntakeRoute -Scenario $Scenario
  $context = Resolve-GitHubIntakeDraftContext `
    -Scenario $Scenario `
    -Issue $Issue `
    -IssueTitle $IssueTitle `
    -IssueUrl $IssueUrl `
    -Branch $Branch `
    -StandingPriority:$StandingPriority `
    -CurrentBranch $CurrentBranch

  $draftOutput = Resolve-GitHubIntakeDraftOutputPath -RouteType $route.routeType -OutputPath $DraftOutputPath
  $executionKind = [string]$route.executionKind
  $issueTemplate = $null
  if ([string]$route.routeType -eq 'issue-template') {
    $issueTemplate = Resolve-GitHubIssueTemplate -TemplateName ([string]$context.templateKey)
  }

  $resolvedTitle = $null
  $labels = @()
  $arguments = [System.Collections.Generic.List[string]]::new()
  $missing = [System.Collections.Generic.List[string]]::new()
  $titleRequired = $false
  $issueRequired = $false
  $branchRequired = $false
  $draftWriteOnApply = $true

  switch ($executionKind) {
    'gh-issue-create' {
      $titleRequired = $true
      $resolvedTitle = if ([string]::IsNullOrWhiteSpace($Title)) { $null } else { $Title.Trim() }
      if (-not $resolvedTitle) {
        $missing.Add('title')
      }

      if ($issueTemplate -and $issueTemplate.PSObject.Properties.Name -contains 'labels') {
        $labels = @($issueTemplate.labels | ForEach-Object { [string]$_ })
      }

      $arguments.Add('issue')
      $arguments.Add('create')
      $arguments.Add('--repo')
      $arguments.Add($RepositoryContext)
      $arguments.Add('--title')
      $arguments.Add($(if ($resolvedTitle) { $resolvedTitle } else { '<title-required>' }))
      $arguments.Add('--body-file')
      $arguments.Add($draftOutput)
      foreach ($label in $labels) {
        $arguments.Add('--label')
        $arguments.Add($label)
      }
    }
    'priority-pr-create' {
      $issueRequired = $true
      $branchRequired = $true
      $resolvedTitle = Resolve-PullRequestTitle -Issue $context.issue -IssueTitle $context.issueTitle -Base $Base
      if ($context.issue -le 0) {
        $missing.Add('issue')
      }
      if ([string]::IsNullOrWhiteSpace($context.branch)) {
        $missing.Add('branch')
      }

      $arguments.Add('tools/npm/run-script.mjs')
      $arguments.Add('priority:pr')
      $arguments.Add('--')
      if ($context.issue -gt 0) {
        $arguments.Add('--issue')
        $arguments.Add([string]$context.issue)
      }
      $arguments.Add('--repo')
      $arguments.Add($RepositoryContext)
      if (-not [string]::IsNullOrWhiteSpace($context.branch)) {
        $arguments.Add('--branch')
        $arguments.Add($context.branch)
      }
      $arguments.Add('--base')
      $arguments.Add($Base)
      $arguments.Add('--title')
      $arguments.Add($resolvedTitle)
      $arguments.Add('--body-file')
      $arguments.Add($draftOutput)
    }
    'branch-orchestrator' {
      $issueRequired = $true
      $draftWriteOnApply = $false
      $resolvedTitle = Resolve-PullRequestTitle -Issue $context.issue -IssueTitle $context.issueTitle -Base $Base
      if ($context.issue -le 0) {
        $missing.Add('issue')
      }

      $arguments.Add('-NoLogo')
      $arguments.Add('-NoProfile')
      $arguments.Add('-File')
      $arguments.Add('tools/Branch-Orchestrator.ps1')
      $arguments.Add('-Issue')
      $arguments.Add([string]$context.issue)
      $arguments.Add('-Execute')
      if (-not [string]::IsNullOrWhiteSpace($Base)) {
        $arguments.Add('-Base')
        $arguments.Add($Base)
      }
      $templateName = if ($route.execution -and -not [string]::IsNullOrWhiteSpace([string]$route.execution.pullRequestTemplate)) {
        [string]$route.execution.pullRequestTemplate
      } else {
        'default'
      }
      if ($templateName -ne 'default') {
        $arguments.Add('-PRTemplate')
        $arguments.Add($templateName)
      }
    }
    'open-link' {
      if ([string]::IsNullOrWhiteSpace($route.targetUrl)) {
        $missing.Add('targetUrl')
      }

      $arguments.Add($(if ([string]::IsNullOrWhiteSpace($route.targetUrl)) { '<target-url>' } else { [string]$route.targetUrl }))
    }
    default {
      throw "Unsupported GitHub intake execution kind '$executionKind'."
    }
  }

  $displayCommand = switch ($executionKind) {
    'branch-orchestrator' { Format-GitHubIntakeCommandLine -Command 'pwsh' -Arguments $arguments.ToArray() }
    'priority-pr-create' { Format-GitHubIntakeCommandLine -Command 'node' -Arguments $arguments.ToArray() }
    'open-link' { Format-GitHubIntakeCommandLine -Command 'start' -Arguments $arguments.ToArray() }
    default { Format-GitHubIntakeCommandLine -Command 'gh' -Arguments $arguments.ToArray() }
  }

  [pscustomobject]@{
    schema            = 'github-intake/execution-plan@v1'
    generatedAtUtc    = $GeneratedAtUtc
    repositoryContext = $RepositoryContext
    scenario          = [string]$route.scenario
    routeType         = [string]$route.routeType
    targetKey         = [string]$route.targetKey
    targetName        = [string]$route.targetName
    summary           = [string]$route.summary
    route             = [pscustomobject]@{
      helperPath     = [string]$route.helperPath
      command        = [string]$route.command
      executeCommand = if ($null -eq $route.executeCommand) { $null } else { [string]$route.executeCommand }
      execution      = $route.execution
    }
    draft             = [pscustomobject]@{
      outputPath        = $draftOutput
      writeOnApply      = $draftWriteOnApply
      issue             = [int]$context.issue
      issueTitle        = if ([string]::IsNullOrWhiteSpace($context.issueTitle)) { $null } else { [string]$context.issueTitle }
      issueUrl          = if ([string]::IsNullOrWhiteSpace($context.issueUrl)) { $null } else { [string]$context.issueUrl }
      base              = if ([string]::IsNullOrWhiteSpace($Base)) { $null } else { $Base }
      branch            = if ([string]::IsNullOrWhiteSpace($context.branch)) { $null } else { [string]$context.branch }
      standingPriority  = [bool]$context.standingPriority
      relatedIssues     = if ([string]::IsNullOrWhiteSpace($RelatedIssues)) { $null } else { $RelatedIssues }
      repositoryContext = $RepositoryContext
      snapshotResolved  = [bool]$context.snapshotResolved
    }
    execution         = [pscustomobject]@{
      kind                = $executionKind
      title               = if ([string]::IsNullOrWhiteSpace($resolvedTitle)) { $null } else { $resolvedTitle }
      labels              = @($labels)
      base                = if ([string]::IsNullOrWhiteSpace($Base)) { $null } else { $Base }
      branch              = if ([string]::IsNullOrWhiteSpace($context.branch)) { $null } else { [string]$context.branch }
      pullRequestTemplate = if ($route.execution -and -not [string]::IsNullOrWhiteSpace([string]$route.execution.pullRequestTemplate)) { [string]$route.execution.pullRequestTemplate } else { $null }
      arguments           = @($arguments)
      displayCommand      = $displayCommand
    }
    requirements      = [pscustomobject]@{
      defaultMode   = 'plan'
      titleRequired = $titleRequired
      issueRequired = $issueRequired
      branchRequired = $branchRequired
      canApply      = (@($missing).Count -eq 0)
      missing       = @($missing)
    }
  }
}

function Invoke-GitHubIntakeExecutionPlan {
  param(
    [pscustomobject]$Plan,
    [scriptblock]$DraftRenderer,
    [scriptblock]$NativeInvoker,
    [scriptblock]$BranchOrchestratorInvoker
  )

  if (-not $Plan) {
    throw 'GitHub intake execution plan is required.'
  }

  if ([string]$Plan.schema -ne 'github-intake/execution-plan@v1') {
    throw "Unsupported execution plan schema '$($Plan.schema)'."
  }

  $missing = @($Plan.requirements.missing)
  if ($missing.Count -gt 0) {
    throw ('Execution plan is missing required inputs: {0}' -f ($missing -join ', '))
  }

  if (-not $DraftRenderer) {
    $draftScriptPath = Join-Path $PSScriptRoot 'New-GitHubIntakeDraft.ps1'
    $DraftRenderer = {
      param([hashtable]$DraftParameters)
      & $draftScriptPath @DraftParameters | Out-Null
      return $DraftParameters.OutputPath
    }.GetNewClosure()
  }

  if (-not $NativeInvoker) {
    $NativeInvoker = {
      param([string]$FilePath, [string[]]$Arguments)
      $output = & $FilePath @Arguments 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw ('Command failed ({0}): {1}' -f $LASTEXITCODE, ((@($output) | Out-String).Trim()))
      }

      return ((@($output) | Out-String).Trim())
    }.GetNewClosure()
  }

  if (-not $BranchOrchestratorInvoker) {
    $orchestratorPath = Join-Path $PSScriptRoot 'Branch-Orchestrator.ps1'
    $BranchOrchestratorInvoker = {
      param([hashtable]$Parameters)
      & $orchestratorPath @Parameters | Out-Null
      return $true
    }.GetNewClosure()
  }

  $draftWritten = $false
  if ($Plan.draft.writeOnApply) {
    $draftParameters = @{
      Scenario          = [string]$Plan.scenario
      Issue             = [int]$Plan.draft.issue
      IssueTitle        = if ($null -eq $Plan.draft.issueTitle) { '' } else { [string]$Plan.draft.issueTitle }
      IssueUrl          = if ($null -eq $Plan.draft.issueUrl) { '' } else { [string]$Plan.draft.issueUrl }
      Base              = if ($null -eq $Plan.draft.base) { '' } else { [string]$Plan.draft.base }
      Branch            = if ($null -eq $Plan.draft.branch) { '' } else { [string]$Plan.draft.branch }
      RepositoryContext = [string]$Plan.draft.repositoryContext
      OutputPath        = [string]$Plan.draft.outputPath
    }
    if ([bool]$Plan.draft.standingPriority) { $draftParameters['StandingPriority'] = $true }
    if ($null -ne $Plan.draft.relatedIssues -and -not [string]::IsNullOrWhiteSpace([string]$Plan.draft.relatedIssues)) {
      $draftParameters['RelatedIssues'] = [string]$Plan.draft.relatedIssues
    }

    & $DraftRenderer $draftParameters | Out-Null
    $draftWritten = $true
  }

  $output = $null
  $commandFilePath = $null
  $commandArguments = @()

  switch ([string]$Plan.execution.kind) {
    'gh-issue-create' {
      $commandFilePath = 'gh'
      $commandArguments = @($Plan.execution.arguments)
      $output = & $NativeInvoker $commandFilePath $commandArguments
    }
    'priority-pr-create' {
      $commandFilePath = 'node'
      $commandArguments = @($Plan.execution.arguments)
      $output = & $NativeInvoker $commandFilePath $commandArguments
    }
    'branch-orchestrator' {
      $commandFilePath = Join-Path $PSScriptRoot 'Branch-Orchestrator.ps1'
      $orchestratorParameters = @{
        Issue   = [int]$Plan.draft.issue
        Execute = $true
      }
      if ($null -ne $Plan.execution.base -and -not [string]::IsNullOrWhiteSpace([string]$Plan.execution.base)) {
        $orchestratorParameters['Base'] = [string]$Plan.execution.base
      }
      if ($null -ne $Plan.execution.pullRequestTemplate -and -not [string]::IsNullOrWhiteSpace([string]$Plan.execution.pullRequestTemplate)) {
        $orchestratorParameters['PRTemplate'] = [string]$Plan.execution.pullRequestTemplate
      }

      $commandArguments = @('-Issue', [string]$orchestratorParameters.Issue, '-Execute')
      if ($orchestratorParameters.ContainsKey('Base')) {
        $commandArguments += @('-Base', [string]$orchestratorParameters.Base)
      }
      if ($orchestratorParameters.ContainsKey('PRTemplate')) {
        $commandArguments += @('-PRTemplate', [string]$orchestratorParameters.PRTemplate)
      }

      $output = & $BranchOrchestratorInvoker $orchestratorParameters
    }
    'open-link' {
      $commandFilePath = $null
      $commandArguments = @()
      $output = if ($Plan.execution.arguments -and $Plan.execution.arguments.Count -gt 0) { [string]$Plan.execution.arguments[0] } else { $null }
    }
    default {
      throw "Unsupported execution kind '$($Plan.execution.kind)'."
    }
  }

  [pscustomobject]@{
    schema          = 'github-intake/execution-result@v1'
    appliedAtUtc    = [DateTime]::UtcNow.ToString('o')
    scenario        = [string]$Plan.scenario
    executionKind   = [string]$Plan.execution.kind
    draftWritten    = $draftWritten
    draftOutputPath = [string]$Plan.draft.outputPath
    commandFilePath = $commandFilePath
    arguments       = @($commandArguments)
    output          = $output
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
  $lines.Add('| Scenario | Route Type | Target | Execution | Helper | Draft Command | Execute Command |')
  $lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
  foreach ($route in @($Report.routes)) {
    $executeCommand = if ([string]::IsNullOrWhiteSpace([string]$route.executeCommand)) { '(none)' } else { [string]$route.executeCommand }
    $executionKind = if ([string]::IsNullOrWhiteSpace([string]$route.executionKind)) { '(none)' } else { [string]$route.executionKind }
    $lines.Add(('| {0} | {1} | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` |' -f $route.scenario, $route.routeType, $route.targetKey, $executionKind, $route.helperPath, $route.command, $executeCommand))
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
  $lines.Add('- Use `Invoke-GitHubIntakeScenario.ps1` for a default dry-run execution plan and explicit `-Apply` mode.')
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
  Invoke-GitHubIntakeExecutionPlan, `
  New-GitHubIntakeAtlasReport, `
  New-GitHubIntakeExecutionPlan, `
  Resolve-GitHubIntakeDraftContext, `
  Resolve-GitHubIntakeDraftOutputPath, `
  Resolve-GitHubIssueSnapshot, `
  Resolve-GitHubIssueTemplate, `
  Resolve-GitHubPullRequestTemplate, `
  Resolve-GitHubIntakeRoute, `
  Resolve-IssueBranchName, `
  Resolve-PullRequestTitle
