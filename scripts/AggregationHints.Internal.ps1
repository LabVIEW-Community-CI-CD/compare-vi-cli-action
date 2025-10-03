function Get-AggregationHintsBlock {
  <#
    .SYNOPSIS
      Builds the aggregationHints block (heuristic/v1) given a collection of test-like objects.
    .DESCRIPTION
      Accepts objects that expose Path, Tags (array or scalar), and Duration (seconds, numeric or string castable).
      Returns a psobject with fields: dominantTags, fileBucketCounts, durationBuckets, suggestions, strategy.
    .PARAMETER Tests
      Collection of test result objects (each may contain Path, Tags, Duration).
  #>
  param(
    [Parameter(ValueFromPipeline)][object[]]$Tests = @()
  )
  begin {
    $tagFreq    = @{}
    $fileCounts = @{}
    $fileBucketCounts = [ordered]@{ small=0; medium=0; large=0 }
    $durationBuckets  = [ordered]@{ subSecond=0; oneToFive=0; overFive=0 }
    function Get-NormalizedIntLocal {
      param([object]$Value)
      if ($null -eq $Value) { return 0 }
      if ($Value -is [System.Array]) { if ($Value.Length -le 1) { return (Get-NormalizedIntLocal -Value ($Value[0])) } return [int]$Value.Length }
      try { return [int]$Value } catch { return 0 }
    }
    function Add-TagFreq([string]$Tag) {
      if ([string]::IsNullOrWhiteSpace($Tag)) { return }
      $tagFreq[$Tag] = (Get-NormalizedIntLocal -Value $tagFreq[$Tag]) + 1
    }
  }
  process {
    foreach ($t in $Tests) {
      if ($null -eq $t) { continue }
      # Path counting
  $pathProp = $t.PSObject.Properties['Path']
  $path = if ($pathProp) { $pathProp.Value } else { $null }
      if ($path) { $fileCounts[$path] = (Get-NormalizedIntLocal -Value $fileCounts[$path]) + 1 }
      # Tag extraction (Tags | Tag | any property containing 'Tag')
      $tagValues = @()
      foreach ($pn in @('Tags','Tag')) { $prop = $t.PSObject.Properties[$pn]; if ($prop -and $prop.Value) { $tagValues += $prop.Value } }
      if (-not $tagValues) {
        $fallback = $t.PSObject.Properties | Where-Object { $_.Name -match 'Tag' -and $_.Value }
        foreach ($pf in $fallback) { $tagValues += $pf.Value }
      }
      foreach ($tv in $tagValues) { Add-TagFreq -Tag ("$tv") }
      # Duration bucketing
      $durProp = $t.PSObject.Properties['Duration']
      if ($durProp) {
        $durRaw = $durProp.Value
        $dur = $null
  if ($durRaw -is [double] -or $durRaw -is [float] -or $durRaw -is [decimal]) { $dur = [double]$durRaw }
  elseif ($durRaw -is [int]) { $dur = [double]$durRaw }
  elseif ($durRaw -is [timespan]) { $dur = [double]$durRaw.TotalSeconds }
  elseif ($durRaw -is [string]) { [void][double]::TryParse($durRaw, [ref]$dur) }
        if ($null -ne $dur) {
          if ($dur -lt 1) { $durationBuckets.subSecond++ }
          elseif ($dur -lt 5) { $durationBuckets.oneToFive++ }
          else { $durationBuckets.overFive++ }
        }
      }
    }
  }
  end {
    $dominantTags = @()
    if ($tagFreq.Count -gt 0) {
      $dominantTags = $tagFreq.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 5 | ForEach-Object { $_.Key }
    }
    foreach ($kv in $fileCounts.GetEnumerator()) {
      $c = Get-NormalizedIntLocal -Value $kv.Value
      if ($c -le 5) { $fileBucketCounts.small++ }
      elseif ($c -le 15) { $fileBucketCounts.medium++ }
      else { $fileBucketCounts.large++ }
    }
    $suggestions = @()
    if ($fileBucketCounts.large -gt 0) { $suggestions += 'split-large-files' }
    if ($durationBuckets.overFive -gt 0) { $suggestions += 'isolate-slow-tests' }
    if (-not $dominantTags -or $dominantTags.Count -eq 0) { $suggestions += 'tag-more-tests' }
    [pscustomobject]@{
      dominantTags     = $dominantTags
      fileBucketCounts = $fileBucketCounts
      durationBuckets  = $durationBuckets
      suggestions      = $suggestions
      strategy         = 'heuristic/v1'
    }
  }
}

