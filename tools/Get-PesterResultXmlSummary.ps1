param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$XmlPath,

  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 30)]
  [int]$StabilizationTimeoutSeconds = 3,

  [Parameter(Mandatory = $false)]
  [ValidateRange(25, 5000)]
  [int]$PollIntervalMilliseconds = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ResultXmlRootAttributes {
  param(
    [Parameter(Mandatory = $true)]
    [string]$XmlText
  )

  $match = [regex]::Match(
    $XmlText,
    '<test-results\b(?<attrs>[^>]*)>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase `
      -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
  if (-not $match.Success) {
    return $null
  }

  $attrs = $match.Groups['attrs'].Value
  $values = [ordered]@{}
  foreach ($name in @('total', 'errors', 'failures', 'not-run')) {
    $attrMatch = [regex]::Match(
      $attrs,
      ('\b{0}="(?<value>\d+)"' -f [regex]::Escape($name)),
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $attrMatch.Success) {
      return $null
    }
    $values[$name] = [int]$attrMatch.Groups['value'].Value
  }

  return [pscustomobject]@{
    Total    = [int]$values['total']
    Errors   = [int]$values['errors']
    Failures = [int]$values['failures']
    Skipped  = [int]$values['not-run']
  }
}

function Test-ResultXmlCloseTag {
  param(
    [Parameter(Mandatory = $true)]
    [string]$XmlText
  )

  return [regex]::IsMatch(
    $XmlText,
    '</test-results>\s*$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

$resolvedXmlPath = [System.IO.Path]::GetFullPath($XmlPath)
$deadline = (Get-Date).AddSeconds($StabilizationTimeoutSeconds)
$lastSize = -1L
$stablePolls = 0
$rawText = $null
$closeTagPresent = $false
$sizeBytes = 0L

while ((Get-Date) -le $deadline) {
  if (Test-Path -LiteralPath $resolvedXmlPath -PathType Leaf) {
    $rawText = Get-Content -LiteralPath $resolvedXmlPath -Raw -ErrorAction Stop
    $sizeBytes = (Get-Item -LiteralPath $resolvedXmlPath -ErrorAction Stop).Length
    $closeTagPresent = Test-ResultXmlCloseTag -XmlText $rawText
    if ($closeTagPresent) {
      break
    }

    if ($sizeBytes -eq $lastSize -and $sizeBytes -gt 0) {
      $stablePolls++
    } else {
      $stablePolls = 0
      $lastSize = $sizeBytes
    }

    if ($stablePolls -ge 2) {
      break
    }
  }

  Start-Sleep -Milliseconds $PollIntervalMilliseconds
}

if (-not $rawText -and (Test-Path -LiteralPath $resolvedXmlPath -PathType Leaf)) {
  $rawText = Get-Content -LiteralPath $resolvedXmlPath -Raw -ErrorAction Stop
  $sizeBytes = (Get-Item -LiteralPath $resolvedXmlPath -ErrorAction Stop).Length
  $closeTagPresent = Test-ResultXmlCloseTag -XmlText $rawText
}

$status = 'missing'
$summarySource = $null
$parseError = $null
$total = $null
$failed = $null
$errors = $null
$skipped = $null

if (-not [string]::IsNullOrWhiteSpace($rawText)) {
  try {
    [xml]$document = $rawText
    $rootNode = $document.'test-results'
    if (-not $rootNode) {
      throw 'Missing test-results root node.'
    }

    $status = 'complete'
    $summarySource = 'xml-dom'
    $total = [int]$rootNode.total
    $failed = [int]$rootNode.failures
    $errors = [int]$rootNode.errors
    $skipped = [int]$rootNode.'not-run'
  } catch {
    $parseError = $_.Exception.Message
    $rootAttributes = Get-ResultXmlRootAttributes -XmlText $rawText
    if ($rootAttributes) {
      $status = if ($closeTagPresent) { 'invalid-root-attributes' } else { 'truncated-root' }
      $summarySource = 'root-attributes'
      $total = [int]$rootAttributes.Total
      $failed = [int]$rootAttributes.Failures
      $errors = [int]$rootAttributes.Errors
      $skipped = [int]$rootAttributes.Skipped
    } else {
      $status = if ($closeTagPresent) { 'invalid' } else { 'truncated' }
    }
  }
}

[pscustomobject]@{
  schema        = 'pester-result-xml-summary@v1'
  path          = $resolvedXmlPath
  status        = $status
  summarySource = $summarySource
  closeTagPresent = [bool]$closeTagPresent
  sizeBytes     = [int64]$sizeBytes
  total         = $total
  failed        = $failed
  errors        = $errors
  skipped       = $skipped
  parseError    = $parseError
}
