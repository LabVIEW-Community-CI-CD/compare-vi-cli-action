# Traceability Matrix Builder (Traceability Matrix Plan v1.0.0)
param(
  [string]$TestsPath = 'tests',
  [string]$ResultsRoot = 'tests/results',
  [string]$OutDir,
  [string[]]$IncludePatterns,
  [string]$RunId,
  [string]$Seed,
  [switch]$RenderHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path '.').Path

if (-not $OutDir) {
  $OutDir = Join-Path $ResultsRoot '_trace'
}
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Write-Host "[TraceMatrix] TestsPath=$TestsPath ResultsRoot=$ResultsRoot OutDir=$OutDir" -ForegroundColor Cyan
if ($IncludePatterns) { Write-Host ("[TraceMatrix] IncludePatterns: {0}" -f ($IncludePatterns -join ', ')) -ForegroundColor Cyan }
if ($RunId) { Write-Host "[TraceMatrix] RunId=$RunId" -ForegroundColor DarkCyan }
if ($Seed)  { Write-Host "[TraceMatrix] Seed=$Seed"   -ForegroundColor DarkCyan }
if ($RenderHtml) { Write-Host "[TraceMatrix] HTML rendering requested." -ForegroundColor DarkCyan }

function Get-TestFiles {
  param(
    [Parameter(Mandatory)][string]$Root,
    [string[]]$Patterns
  )
  $files = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue | Sort-Object FullName)
  if ($Patterns -and $Patterns.Count -gt 0) {
    $patterns = $Patterns
    $files = $files | Where-Object {
      $name = $_.Name
      foreach ($pattern in $patterns) {
        if ($name -like $pattern) { return $true }
      }
      return $false
    }
  }
  ,$files
}

function New-Slug {
  param([Parameter(Mandatory)][string]$FileName)
  ($FileName -replace '[^A-Za-z0-9]+', '-').Trim('-')
}

function Get-Annotations {
  param([System.IO.FileInfo]$File)
  $content = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop
  $reqSet = New-Object System.Collections.Generic.HashSet[string]
  $adrSet = New-Object System.Collections.Generic.HashSet[string]

  foreach ($match in [regex]::Matches($content, 'REQ:([A-Za-z0-9_\-]+)')) {
    $reqSet.Add($match.Groups[1].Value.ToUpperInvariant()) | Out-Null
  }
  foreach ($match in [regex]::Matches($content, 'ADR:([0-9]{4})')) {
    $adrSet.Add($match.Groups[1].Value) | Out-Null
  }

  $headerLines = Get-Content -LiteralPath $File.FullName -TotalCount 50 -ErrorAction Stop
  foreach ($line in $headerLines) {
    $m = [regex]::Match($line, '#\s*trace:\s*(?<pairs>.+)', 'IgnoreCase')
    if (-not $m.Success) { continue }
    $pairs = $m.Groups['pairs'].Value -split '[,;]'
    foreach ($pair in $pairs) {
      $kv = $pair.Split('=',2).ForEach({ $_.Trim() })
      if ($kv.Count -ne 2) { continue }
      $key = $kv[0].ToLowerInvariant()
      $valueTokens = $kv[1].Split([char[]]@(' ','|'),[System.StringSplitOptions]::RemoveEmptyEntries)
      switch ($key) {
        'req' { foreach ($val in $valueTokens) { $reqSet.Add($val.ToUpperInvariant()) | Out-Null } }
        'adr' { foreach ($val in $valueTokens) { if ($val -match '^\d{4}$') { $adrSet.Add($val) | Out-Null } } }
      }
    }
  }

  $reqArray = @([System.Linq.Enumerable]::ToArray($reqSet) | Sort-Object)
  $adrArray = @([System.Linq.Enumerable]::ToArray($adrSet) | Sort-Object)
  [pscustomobject]@{
    Requirements = $reqArray
    Adrs         = $adrArray
  }
}

function Get-RequirementCatalog {
  param([string]$Directory)
  $items = @{}
  $files = Get-ChildItem -LiteralPath $Directory -File -Filter '*.md' -ErrorAction SilentlyContinue
  foreach ($file in $files) {
    $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    $titleMatch = [regex]::Match($content, '^\s*#\s+(?<title>.+)$', 'Multiline')
    $title = if ($titleMatch.Success) { $titleMatch.Groups['title'].Value.Trim() } else { $id }
    $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\','/')
    $items[$id.ToUpperInvariant()] = [pscustomobject]@{
      Id    = $id.ToUpperInvariant()
      Title = $title
      Path  = $relative
    }
  }
  $items
}

function Get-AdrCatalog {
  param([string]$Directory)
  $items = @{}
  $files = Get-ChildItem -LiteralPath $Directory -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^\d{4}-' }
  foreach ($file in $files) {
    $id = $file.BaseName.Substring(0,4)
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    $titleMatch = [regex]::Match($content, '^\s*#\s+(?<title>.+)$', 'Multiline')
    $title = if ($titleMatch.Success) { $titleMatch.Groups['title'].Value.Trim() } else { $file.BaseName }
    $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\','/')
    $items[$id] = [pscustomobject]@{
      Id    = $id
      Title = $title
      Path  = $relative
    }
  }
  $items
}

function Read-TestResult {
  param(
    [string]$ResultsRoot,
    [string]$Slug
  )
  $dir = Join-Path $ResultsRoot 'pester'
  $dir = Join-Path $dir $Slug
  $xmlPath = Join-Path $dir 'pester-results.xml'
  if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
    return [pscustomobject]@{
      Exists     = $false
      Passed     = 0
      Failed     = 0
      Skipped    = 0
      Errors     = 0
      DurationMs = $null
      Path       = $xmlPath
    }
  }
  try {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
  } catch {
    Write-Warning "[TraceMatrix] Failed to parse $xmlPath : $($_.Exception.Message)"
    return [pscustomobject]@{
      Exists     = $true
      Passed     = 0
      Failed     = 0
      Skipped    = 0
      Errors     = 0
      DurationMs = $null
      Path       = $xmlPath
    }
  }
  $nodes = $doc.SelectNodes('//test-case')
  $testCases = @()
  if ($nodes) {
    foreach ($node in $nodes) { $testCases += $node }
  }
  $passed  = (@($testCases | Where-Object { $_.result -eq 'Passed'  })).Count
  $failed  = (@($testCases | Where-Object { $_.result -eq 'Failed'  })).Count
  $errors  = (@($testCases | Where-Object { $_.result -eq 'Error'   })).Count
  $skipped = (@($testCases | Where-Object { $_.result -eq 'Skipped' -or $_.result -eq 'Ignored' })).Count
  $durationTotal = 0.0
  foreach ($case in $testCases) {
    if ($case.time -and [double]::TryParse($case.time, [ref]$null)) {
      $durationTotal += [double]$case.time
    }
  }
  [pscustomobject]@{
    Exists     = $true
    Passed     = $passed
    Failed     = $failed + $errors
    Skipped    = $skipped
    Errors     = $errors
    DurationMs = if ($durationTotal -gt 0) { [int]([math]::Round($durationTotal * 1000)) } else { $null }
    Path       = $xmlPath
  }
}

$tests = @()

$requirementCatalog = Get-RequirementCatalog -Directory (Join-Path $repoRoot 'docs/requirements')
$adrCatalog          = Get-AdrCatalog -Directory (Join-Path $repoRoot 'docs/adr')

$requirementCoverage = @{}
$adrCoverage = @{}

$testFiles = Get-TestFiles -Root $TestsPath -Patterns $IncludePatterns
foreach ($file in $testFiles) {
  $ann = Get-Annotations -File $file
  $slug = New-Slug -FileName $file.Name
  $result = Read-TestResult -ResultsRoot $ResultsRoot -Slug $slug
  $status = 'Unknown'
  if ($result.Exists -and $result.Failed -gt 0) { $status = 'Failed' }
  elseif ($result.Exists -and $result.Passed -gt 0 -and $result.Failed -eq 0) { $status = 'Passed' }
  elseif ($result.Exists) { $status = 'Unknown' }

  $relativeFile = [IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\','/')
  $testEntry = [ordered]@{
    file        = $relativeFile
    slug        = $slug
    status      = $status
    reqIds      = $ann.Requirements
    adrIds      = $ann.Adrs
    passed      = $result.Passed
    failed      = $result.Failed
    skipped     = $result.Skipped
    durationMs  = $result.DurationMs
    resultsXml  = [IO.Path]::GetRelativePath($repoRoot, $result.Path).Replace('\','/')
  }
  $tests += $testEntry

  foreach ($req in $ann.Requirements) {
    if (-not $requirementCoverage.ContainsKey($req)) {
      $requirementCoverage[$req] = New-Object System.Collections.Generic.List[hashtable]
    }
    $requirementCoverage[$req].Add(@{ file=$relativeFile; status=$status })
  }
  foreach ($adr in $ann.Adrs) {
    if (-not $adrCoverage.ContainsKey($adr)) {
      $adrCoverage[$adr] = New-Object System.Collections.Generic.List[hashtable]
    }
    $adrCoverage[$adr].Add(@{ file=$relativeFile; status=$status })
  }
}

function Resolve-RequirementEntry {
  param([string]$Id,[hashtable]$Coverage)
  $catalog = $requirementCatalog
  $tests = if ($Coverage.ContainsKey($Id)) { @($Coverage[$Id] | ForEach-Object { $_ }) } else { @() }
  $status = 'Unknown'
  if ($tests | Where-Object { $_.status -eq 'Failed' }) { $status = 'Failed' }
  elseif ($tests | Where-Object { $_.status -eq 'Passed' }) { $status = 'Passed' }
  $entry = if ($catalog.ContainsKey($Id)) { $catalog[$Id] } else { $null }
  $testFiles = @($tests | ForEach-Object { $_.file } | Sort-Object -Unique)
  [ordered]@{
    title      = if ($entry) { $entry.Title } else { "Unknown requirement ($Id)" }
    url        = if ($entry) { $entry.Path } else { $null }
    tests      = $testFiles
    status     = $status
    passCount  = (@($tests | Where-Object { $_.status -eq 'Passed' })).Count
    failCount  = (@($tests | Where-Object { $_.status -eq 'Failed' })).Count
  }
}

function Resolve-AdrEntry {
  param([string]$Id,[hashtable]$Coverage)
  $catalog = $adrCatalog
  $tests = if ($Coverage.ContainsKey($Id)) { @($Coverage[$Id] | ForEach-Object { $_ }) } else { @() }
  $status = 'Unknown'
  if ($tests | Where-Object { $_.status -eq 'Failed' }) { $status = 'Failed' }
  elseif ($tests | Where-Object { $_.status -eq 'Passed' }) { $status = 'Passed' }
  $entry = if ($catalog.ContainsKey($Id)) { $catalog[$Id] } else { $null }
  $testFiles = @($tests | ForEach-Object { $_.file } | Sort-Object -Unique)
  [ordered]@{
    title      = if ($entry) { $entry.Title } else { "Unknown ADR ($Id)" }
    url        = if ($entry) { $entry.Path } else { $null }
    tests      = $testFiles
    status     = $status
  }
}

$requirementsNode = [ordered]@{}
$allRequirementIds = @($requirementCatalog.Keys + $requirementCoverage.Keys | Sort-Object -Unique)
foreach ($id in $allRequirementIds) {
  $requirementsNode[$id] = Resolve-RequirementEntry -Id $id -Coverage $requirementCoverage
}

$adrsNode = [ordered]@{}
$allAdrIds = @($adrCatalog.Keys + $adrCoverage.Keys | Sort-Object -Unique)
foreach ($id in $allAdrIds) {
  $adrsNode[$id] = Resolve-AdrEntry -Id $id -Coverage $adrCoverage
}

$unknownRequirementSet = New-Object System.Collections.Generic.HashSet[string]
$testsWithoutReq = @()
foreach ($test in $tests) {
  $knownReq = @($test.reqIds | Where-Object { $requirementCatalog.ContainsKey($_) })
  $knownAdr = @($test.adrIds | Where-Object { $adrCatalog.ContainsKey($_) })
  foreach ($u in ($test.reqIds | Where-Object { -not $requirementCatalog.ContainsKey($_) })) { $null = $unknownRequirementSet.Add($u) }
  if ($knownReq.Count -eq 0 -and $knownAdr.Count -eq 0) { $testsWithoutReq += $test.file }
}
$requirementsWithoutTests = @($requirementsNode.GetEnumerator() | Where-Object { $_.Value.tests.Count -eq 0 } | ForEach-Object { $_.Key })
$adrsWithoutTests = @($adrsNode.GetEnumerator() | Where-Object { $_.Value.tests.Count -eq 0 } | ForEach-Object { $_.Key })

$summary = [ordered]@{
  generatedAt = (Get-Date).ToString('o')
  runId       = $RunId
  seed        = $Seed
  files       = [ordered]@{
    total      = (@($tests)).Count
    covered    = (@($tests | Where-Object { $_.reqIds.Count -gt 0 -or $_.adrIds.Count -gt 0 })).Count
    uncovered  = (@($tests | Where-Object { $_.reqIds.Count -eq 0 -and $_.adrIds.Count -eq 0 })).Count
  }
  requirements = [ordered]@{
    total      = (@($requirementsNode.GetEnumerator())).Count
    covered    = (@($requirementsNode.GetEnumerator() | Where-Object { $_.Value.tests.Count -gt 0 })).Count
    uncovered  = (@($requirementsNode.GetEnumerator() | Where-Object { $_.Value.tests.Count -eq 0 })).Count
  }
  adrs = [ordered]@{
    total      = (@($adrsNode.GetEnumerator())).Count
    covered    = (@($adrsNode.GetEnumerator() | Where-Object { $_.Value.tests.Count -gt 0 })).Count
    uncovered  = (@($adrsNode.GetEnumerator() | Where-Object { $_.Value.tests.Count -eq 0 })).Count
  }
}

$gaps = [ordered]@{
  requirementsWithoutTests = $requirementsWithoutTests
  testsWithoutRequirements = $testsWithoutReq
  adrsWithoutTests         = $adrsWithoutTests
  unknownRequirementIds    = @($unknownRequirementSet | Sort-Object -Unique)
}

$matrix = [ordered]@{
  schema       = 'trace-matrix/v1'
  summary      = $summary
  requirements = $requirementsNode
  adrs         = $adrsNode
  tests        = $tests
  gaps         = $gaps
}

$jsonPath = Join-Path $OutDir 'trace-matrix.json'
$json = $matrix | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $jsonPath -Value $json -Encoding utf8
Write-Host "[TraceMatrix] Wrote $jsonPath" -ForegroundColor Green

if ($RenderHtml) {
  $testLookup = @{}
  foreach ($test in $tests) { $testLookup[$test.file] = $test }

  function Get-StatusClass($status) {
    switch ($status) {
      'Passed' { 'chip pass' }
      'Failed' { 'chip fail' }
      default  { 'chip unk' }
    }
  }
  $htmlPath = Join-Path $OutDir 'trace-matrix.html'
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.AppendLine('<!DOCTYPE html>')
  $null = $sb.AppendLine('<html><head><meta charset="utf-8"/><title>Test Traceability Matrix</title>')
  $null = $sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:14px;margin:16px;} table{border-collapse:collapse;width:100%;margin-bottom:20px;} th,td{border:1px solid #ddd;padding:6px;text-align:left;} th{background:#f5f5f5;} .chip{padding:2px 8px;border-radius:12px;color:#fff;font-size:12px;} .chip.pass{background:#2e7d32;} .chip.fail{background:#c62828;} .chip.unk{background:#6d6d6d;} .muted{color:#666;} a{color:#1769aa;text-decoration:none;} a:hover{text-decoration:underline;}</style>')
  $null = $sb.AppendLine('</head><body>')
  $null = $sb.AppendLine('<h1>Test Traceability Matrix</h1>')
  $null = $sb.AppendFormat('<p>Generated: {0}</p>', $summary.generatedAt) | Out-Null
  if ($RunId) { $null = $sb.AppendFormat('<p>Run ID: <code>{0}</code></p>', $RunId) | Out-Null }
  if ($Seed)  { $null = $sb.AppendFormat('<p>Seed: <code>{0}</code></p>', $Seed) | Out-Null }

  $null = $sb.AppendLine('<h2>Requirements Coverage</h2>')
  $null = $sb.AppendLine('<table><tr><th>Requirement</th><th>Status</th><th>#Tests</th><th>Tests</th></tr>')
  foreach ($entry in $requirementsNode.GetEnumerator() | Sort-Object Name) {
    $id = $entry.Key
    $data = $entry.Value
    $statusClass = Get-StatusClass $data.status
    $docLink = if ($data.url) { "<a href=""$([IO.Path]::GetRelativePath($OutDir, (Join-Path $repoRoot $data.url)).Replace('\','/'))"">$id</a>" } else { $id }
    $testsCell = if ($data.tests.Count -gt 0) {
      ($data.tests | ForEach-Object {
        if ($testLookup.ContainsKey($_)) {
          $xmlAbs = Join-Path $repoRoot $testLookup[$_].resultsXml
          if (Test-Path -LiteralPath $xmlAbs) {
            $rel = [IO.Path]::GetRelativePath($OutDir, $xmlAbs).Replace('\','/')
            "<a href=""$rel"">$_</a>"
          } else {
            $_
          }
        } else {
          $_
        }
      }) -join '<br/>'
    } else { '<span class="muted">—</span>' }
    $null = $sb.AppendFormat('<tr><td>{0}</td><td><span class="{1}">{2}</span></td><td>{3}</td><td>{4}</td></tr>',
      $docLink, $statusClass, $data.status, $data.tests.Count, $testsCell) | Out-Null
  }
  $null = $sb.AppendLine('</table>')

  $null = $sb.AppendLine('<h2>ADR Coverage</h2>')
  $null = $sb.AppendLine('<table><tr><th>ADR</th><th>Status</th><th>#Tests</th><th>Tests</th></tr>')
  foreach ($entry in $adrsNode.GetEnumerator() | Sort-Object Name) {
    $id = $entry.Key
    $data = $entry.Value
    $statusClass = Get-StatusClass $data.status
    $docLink = if ($data.url) { "<a href=""$([IO.Path]::GetRelativePath($OutDir, (Join-Path $repoRoot $data.url)).Replace('\','/'))"">$id</a>" } else { $id }
    $testsCell = if ($data.tests.Count -gt 0) {
      ($data.tests | ForEach-Object {
        if ($testLookup.ContainsKey($_)) {
          $xmlAbs = Join-Path $repoRoot $testLookup[$_].resultsXml
          if (Test-Path -LiteralPath $xmlAbs) {
            $rel = [IO.Path]::GetRelativePath($OutDir, $xmlAbs).Replace('\','/')
            "<a href=""$rel"">$_</a>"
          } else {
            $_
          }
        } else {
          $_
        }
      }) -join '<br/>'
    } else { '<span class="muted">—</span>' }
    $null = $sb.AppendFormat('<tr><td>{0}</td><td><span class="{1}">{2}</span></td><td>{3}</td><td>{4}</td></tr>',
      $docLink, $statusClass, $data.status, $data.tests.Count, $testsCell) | Out-Null
  }
  $null = $sb.AppendLine('</table>')

  $null = $sb.AppendLine('<h2>Tests</h2>')
  $null = $sb.AppendLine('<table><tr><th>Test File</th><th>Status</th><th>Requirements</th><th>ADRs</th></tr>')
  foreach ($test in $tests | Sort-Object file) {
    $statusClass = Get-StatusClass $test.status
    $reqList = if ($test.reqIds.Count -gt 0) { ($test.reqIds | ForEach-Object { $_ }) -join '<br/>' } else { '<span class="muted">—</span>' }
    $adrList = if ($test.adrIds.Count -gt 0) { ($test.adrIds | ForEach-Object { $_ }) -join '<br/>' } else { '<span class="muted">—</span>' }
    $xmlAbs = Join-Path $repoRoot $test.resultsXml
    if (Test-Path -LiteralPath $xmlAbs) {
      $xmlRel = [IO.Path]::GetRelativePath($OutDir, $xmlAbs).Replace('\','/')
      $fileCell = "<a href=""$xmlRel"">$($test.file)</a>"
    } else {
      $fileCell = $test.file
    }
    $null = $sb.AppendFormat('<tr><td>{0}</td><td><span class="{1}">{2}</span></td><td>{3}</td><td>{4}</td></tr>',
      $fileCell, $statusClass, $test.status, $reqList, $adrList) | Out-Null
  }
  $null = $sb.AppendLine('</table>')

  $null = $sb.AppendLine('</body></html>')
  Set-Content -LiteralPath $htmlPath -Value $sb.ToString() -Encoding utf8
  Write-Host "[TraceMatrix] Wrote $htmlPath" -ForegroundColor Green
}

exit 0
