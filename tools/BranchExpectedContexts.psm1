Set-StrictMode -Version Latest

function Read-BranchPolicyFile {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Branch required-check policy file not found: $Path"
  }

  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50)
}

function Resolve-PatternValue {
  param(
    [AllowNull()][psobject]$Mapping,
    [Parameter(Mandatory)][string]$BranchName
  )

  if (-not $Mapping) {
    return $null
  }

  foreach ($prop in $Mapping.PSObject.Properties) {
    if ($prop.Name -eq $BranchName) {
      return $prop.Value
    }
  }

  $bestMatch = $null
  $bestSpecificity = -1
  foreach ($prop in $Mapping.PSObject.Properties) {
    $pattern = $prop.Name
    if ($pattern -eq 'default') {
      continue
    }
    if ($pattern -notmatch '[\*\?]') {
      continue
    }
    if ($BranchName -like $pattern) {
      $specificity = ($pattern -replace '[\*\?]', '').Length
      if ($specificity -gt $bestSpecificity) {
        $bestSpecificity = $specificity
        $bestMatch = $prop.Value
      }
    }
  }

  if ($null -ne $bestMatch) {
    return $bestMatch
  }

  foreach ($prop in $Mapping.PSObject.Properties) {
    if ($prop.Name -eq 'default') {
      return $prop.Value
    }
  }

  return $null
}

function Resolve-BranchExpectedContexts {
  param(
    [AllowNull()][psobject]$Policy,
    [Parameter(Mandatory)][string]$BranchName
  )

  if (-not $Policy) {
    return @()
  }

  $branchClassId = $null
  if ($Policy.PSObject.Properties.Name -contains 'branchClassBindings') {
    $resolvedBranchClass = Resolve-PatternValue -Mapping $Policy.branchClassBindings -BranchName $BranchName
    if ($resolvedBranchClass) {
      $branchClassId = [string]$resolvedBranchClass
    }
  }

  $expectedRaw = @()
  if ($branchClassId -and $Policy.PSObject.Properties.Name -contains 'branchClassRequiredChecks') {
    $expectedRaw = @(Resolve-PatternValue -Mapping $Policy.branchClassRequiredChecks -BranchName $branchClassId)
  }
  if ($expectedRaw.Count -eq 0 -and $Policy.PSObject.Properties.Name -contains 'branches') {
    $expectedRaw = @(Resolve-PatternValue -Mapping $Policy.branches -BranchName $BranchName)
  }

  return @($expectedRaw | Where-Object { $_ } | Sort-Object -Unique)
}

function Resolve-BranchExpectedContextsFromPath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$BranchName
  )

  $policy = Read-BranchPolicyFile -Path $Path
  return @(Resolve-BranchExpectedContexts -Policy $policy -BranchName $BranchName)
}

Export-ModuleMember -Function `
  Read-BranchPolicyFile, `
  Resolve-PatternValue, `
  Resolve-BranchExpectedContexts, `
  Resolve-BranchExpectedContextsFromPath
