Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:ToolsRoot = Split-Path -Parent $script:ModuleRoot
$script:BundleRoot = Split-Path -Parent $script:ToolsRoot

function Get-CompareVIScriptPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $candidate = Join-Path $script:ToolsRoot $Name
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "CompareVI script '$Name' not found at $candidate"
  }
  return $candidate
}

function Invoke-CompareVIHistory {
  [CmdletBinding(DefaultParameterSetName = 'Default')]
  param(
    [Parameter(Mandatory = $true)]
    [Alias('ViName')]
    [string]$TargetPath,

    [Alias('Branch')]
    [string]$StartRef = 'HEAD',
    [string]$EndRef,
    [int]$MaxPairs,

    [bool]$FlagNoAttr = $true,
    [bool]$FlagNoFp = $true,
    [bool]$FlagNoFpPos = $true,
    [bool]$FlagNoBdCosm = $true,
    [bool]$ForceNoBd = $true,
    [string]$AdditionalFlags,
    [string]$LvCompareArgs,
    [switch]$ReplaceFlags,

    [string[]]$Mode = @('default'),
    [switch]$FailFast,
    [switch]$FailOnDiff,
    [switch]$Quiet,

    [string]$ResultsDir = 'tests/results/ref-compare/history',
    [string]$OutPrefix,
    [string]$ManifestPath,
    [switch]$Detailed,
    [switch]$RenderReport,
    [ValidateSet('html','xml','text')]
    [string]$ReportFormat = 'html',
    [switch]$KeepArtifactsOnNoDiff,
    [string]$InvokeScriptPath,

    [string]$GitHubOutputPath,
    [string]$StepSummaryPath,

    [switch]$IncludeMergeParents
  )

  $compareScript = Get-CompareVIScriptPath -Name 'Compare-VIHistory.ps1'
  $env:COMPAREVI_SCRIPTS_ROOT = $script:BundleRoot
  try {
    & $compareScript @PSBoundParameters
  } finally {
    Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
  }
}

function Invoke-CompareRefsToTemp {
  [CmdletBinding(DefaultParameterSetName = 'ByPath')]
  param(
    [Parameter(ParameterSetName = 'ByPath', Mandatory = $true)][string]$Path,
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)][string]$ViName,
    [Parameter(ParameterSetName = 'ByPath', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)][string]$RefA,
    [Parameter(ParameterSetName = 'ByPath', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)][string]$RefB,
    [string]$ResultsDir = 'tests/results/ref-compare',
    [string]$OutName,
    [switch]$Quiet,
    [switch]$Detailed,
    [switch]$RenderReport,
    [ValidateSet('html','xml','text')]
    [string]$ReportFormat = 'html',
    [string]$LvCompareArgs,
    [switch]$ReplaceFlags,
    [string]$LvComparePath,
    [string]$LabVIEWExePath,
    [string]$InvokeScriptPath,
    [switch]$LeakCheck,
    [double]$LeakGraceSeconds = 1.5,
    [string]$LeakJsonPath,
    [switch]$FailOnDiff
  )

  $compareScript = Get-CompareVIScriptPath -Name 'Compare-RefsToTemp.ps1'
  & $compareScript @PSBoundParameters
}

Export-ModuleMember -Function Invoke-CompareVIHistory, Invoke-CompareRefsToTemp
