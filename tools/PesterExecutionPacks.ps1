Set-StrictMode -Version Latest

function Get-PesterExecutionPackCatalog {
  $catalog = [ordered]@{
    full = [ordered]@{
      name = 'full'
      description = 'Full Pester suite'
      includePatterns = @()
      aliases = @('all', 'default')
    }
    comparevi = [ordered]@{
      name = 'comparevi'
      description = 'CompareVI contract and CLI coverage'
      includePatterns = @('CompareVI*.ps1', 'CanonicalCli.Tests.ps1', 'Args.Tokenization.Tests.ps1')
      aliases = @('compare-vi')
    }
    dispatcher = [ordered]@{
      name = 'dispatcher'
      description = 'Dispatcher, nested execution, and invoker coverage'
      includePatterns = @('Invoke-PesterTests*.ps1', 'PesterAvailability.Tests.ps1', 'NestedDispatcher*.Tests.ps1')
      aliases = @('dispatch')
    }
    workflow = [ordered]@{
      name = 'workflow'
      description = 'Workflow, artifact, and orchestration coverage'
      includePatterns = @(
        'Workflow*.ps1',
        'On-FixtureValidationFail.Tests.ps1',
        'Watch.FlakyRecovery.Tests.ps1',
        'FunctionShadowing*.ps1',
        'FunctionProxy.Tests.ps1',
        'RunSummary.Tool*.ps1',
        'Action.CompositeOutputs.Tests.ps1',
        'Binding.MinRepro.Tests.ps1',
        'ArtifactTracking*.ps1',
        'Guard.*.Tests.ps1'
      )
      aliases = @('orchestration')
    }
    fixtures = [ordered]@{
      name = 'fixtures'
      description = 'Fixture validation and fixture-driven comparison coverage'
      includePatterns = @(
        'Fixtures.*.ps1',
        'FixtureValidation*.ps1',
        'FixtureSummary*.ps1',
        'ViBinaryHandling.Tests.ps1',
        'FixtureValidationDiff.Tests.ps1'
      )
      aliases = @('fixture')
    }
    psummary = [ordered]@{
      name = 'psummary'
      description = 'Pester summary and failure-detail rendering coverage'
      includePatterns = @('PesterSummary*.ps1', 'Write-PesterSummaryToStepSummary*.ps1', 'AggregationHints*.ps1')
      aliases = @('summary')
    }
    schema = [ordered]@{
      name = 'schema'
      description = 'Schema and schema-lite validation coverage'
      includePatterns = @('Schema.*.ps1', 'SchemaLite*.ps1')
      aliases = @('schemas')
    }
    loop = [ordered]@{
      name = 'loop'
      description = 'Loop and autonomous integration control coverage'
      includePatterns = @('CompareLoop*.ps1', 'Run-AutonomousIntegrationLoop*.ps1', 'LoopMetrics.Tests.ps1', 'Integration-ControlLoop*.ps1', 'IntegrationControlLoop*.ps1')
      aliases = @('control-loop')
    }
  }

  return $catalog
}

function Get-PesterExecutionPackNames {
  return @((Get-PesterExecutionPackCatalog).Keys)
}

function ConvertTo-PesterExecutionPackPatterns {
  param(
    [AllowNull()]
    [AllowEmptyCollection()]
    [object]$Patterns
  )

  $tokens = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @($Patterns)) {
    if ($null -eq $candidate) { continue }
    foreach ($segment in ([string]$candidate -split "[`r`n,;]")) {
      $token = $segment.Trim()
      if ([string]::IsNullOrWhiteSpace($token)) { continue }
      if (-not $tokens.Contains($token)) {
        $tokens.Add($token) | Out-Null
      }
    }
  }

  return @($tokens.ToArray())
}

function Resolve-PesterExecutionPack {
  [CmdletBinding()]
  param(
    [AllowEmptyString()]
    [string]$ExecutionPack = 'full',
    [AllowNull()]
    [AllowEmptyCollection()]
    [object]$RefineIncludePatterns
  )

  $catalog = Get-PesterExecutionPackCatalog
  $requestedPack = if ([string]::IsNullOrWhiteSpace($ExecutionPack)) { 'full' } else { $ExecutionPack.Trim().ToLowerInvariant() }
  $resolved = $null

  foreach ($entry in $catalog.GetEnumerator()) {
    $candidate = $entry.Value
    if ($requestedPack -eq $candidate.name) {
      $resolved = $candidate
      break
    }
    if (@($candidate.aliases) -contains $requestedPack) {
      $resolved = $candidate
      break
    }
  }

  if ($null -eq $resolved) {
    $supported = @(
      $catalog.Values |
        ForEach-Object { $_.name } |
        Sort-Object
    ) -join ', '
    throw "Unsupported execution pack '$ExecutionPack'. Supported packs: $supported"
  }

  $basePatterns = ConvertTo-PesterExecutionPackPatterns -Patterns $resolved.includePatterns
  $refinePatterns = ConvertTo-PesterExecutionPackPatterns -Patterns $RefineIncludePatterns
  $effectivePatterns = New-Object System.Collections.Generic.List[string]
  foreach ($token in @($basePatterns + $refinePatterns)) {
    if (-not [string]::IsNullOrWhiteSpace($token) -and -not $effectivePatterns.Contains($token)) {
      $effectivePatterns.Add($token) | Out-Null
    }
  }

  return [pscustomobject]@{
    executionPack = [string]$resolved.name
    executionPackSource = if ([string]::IsNullOrWhiteSpace($ExecutionPack)) { 'default' } else { 'declared' }
    executionPackDescription = [string]$resolved.description
    executionPackAliases = @($resolved.aliases)
    baseIncludePatterns = @($basePatterns)
    refineIncludePatterns = @($refinePatterns)
    effectiveIncludePatterns = @($effectivePatterns.ToArray())
  }
}
