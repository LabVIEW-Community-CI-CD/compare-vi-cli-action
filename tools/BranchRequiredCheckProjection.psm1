Set-StrictMode -Version Latest

function Get-ObjectPropertyValue {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function Normalize-CheckList {
  param([AllowNull()][object]$Value)

  $list = @()
  if ($null -ne $Value) {
    $list = @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  return @($list | Sort-Object -Unique)
}

function Resolve-PatternValue {
  param(
    [AllowNull()][object]$Mapping,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $Mapping) {
    return $null
  }

  $exact = Get-ObjectPropertyValue -Object $Mapping -Name $Name
  if ($null -ne $exact) {
    return $exact
  }

  foreach ($property in $Mapping.PSObject.Properties) {
    if ($property.Name -eq $Name) {
      return $property.Value
    }

    $pattern = [System.Management.Automation.WildcardPattern]::new(
      $property.Name,
      [System.Management.Automation.WildcardOptions]::IgnoreCase
    )
    if ($pattern.IsMatch($Name)) {
      return $property.Value
    }
  }

  return $null
}

function Resolve-ProjectedBranchClassId {
  param(
    [Parameter(Mandatory)][object]$BranchPolicy,
    [Parameter(Mandatory)][string]$BranchName,
    [AllowNull()][string]$PreferredBranchClassId
  )

  $mappedBranchClassId = [string](Resolve-PatternValue -Mapping (Get-ObjectPropertyValue -Object $BranchPolicy -Name 'branchClassBindings') -Name $BranchName)
  if (-not [string]::IsNullOrWhiteSpace($PreferredBranchClassId) -and
      -not [string]::IsNullOrWhiteSpace($mappedBranchClassId) -and
      $PreferredBranchClassId -ne $mappedBranchClassId) {
    throw "Branch '$BranchName' declares branch_class_id '$PreferredBranchClassId' but branch-required-checks maps it to '$mappedBranchClassId'."
  }

  if (-not [string]::IsNullOrWhiteSpace($PreferredBranchClassId)) {
    return $PreferredBranchClassId
  }

  if (-not [string]::IsNullOrWhiteSpace($mappedBranchClassId)) {
    return $mappedBranchClassId
  }

  return $null
}

function Resolve-BranchRequiredCheckProjection {
  param(
    [Parameter(Mandatory)][object]$BranchPolicy,
    [Parameter(Mandatory)][string]$BranchName,
    [AllowNull()][string]$BranchClassId
  )

  $explicitChecks = @(Normalize-CheckList -Value (Resolve-PatternValue -Mapping (Get-ObjectPropertyValue -Object $BranchPolicy -Name 'branches') -Name $BranchName))
  if ($explicitChecks.Count -gt 0) {
    return [pscustomobject]@{
      branchName = $BranchName
      branchClassId = Resolve-ProjectedBranchClassId -BranchPolicy $BranchPolicy -BranchName $BranchName -PreferredBranchClassId $BranchClassId
      requiredChecks = @($explicitChecks)
    }
  }

  $resolvedBranchClassId = Resolve-ProjectedBranchClassId -BranchPolicy $BranchPolicy -BranchName $BranchName -PreferredBranchClassId $BranchClassId
  if ([string]::IsNullOrWhiteSpace($resolvedBranchClassId)) {
    return [pscustomobject]@{
      branchName = $BranchName
      branchClassId = $null
      requiredChecks = @()
    }
  }

  return [pscustomobject]@{
    branchName = $BranchName
    branchClassId = $resolvedBranchClassId
    requiredChecks = @(Normalize-CheckList -Value (Resolve-PatternValue -Mapping (Get-ObjectPropertyValue -Object $BranchPolicy -Name 'branchClassRequiredChecks') -Name $resolvedBranchClassId))
  }
}

function Resolve-PriorityPolicyBranchRequiredChecks {
  param(
    [Parameter(Mandatory)][object]$PriorityPolicy,
    [Parameter(Mandatory)][object]$BranchPolicy,
    [Parameter(Mandatory)][string]$BranchName
  )

  $branchNode = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PriorityPolicy -Name 'branches') -Name $BranchName
  if ($null -eq $branchNode) {
    return @()
  }

  $explicitChecks = @(Normalize-CheckList -Value (Get-ObjectPropertyValue -Object $branchNode -Name 'required_status_checks'))
  if ($explicitChecks.Count -gt 0) {
    return $explicitChecks
  }

  return @((Resolve-BranchRequiredCheckProjection -BranchPolicy $BranchPolicy -BranchName $BranchName -BranchClassId ([string](Get-ObjectPropertyValue -Object $branchNode -Name 'branch_class_id'))).requiredChecks)
}

function Resolve-PriorityPolicyRulesetRequiredChecks {
  param(
    [Parameter(Mandatory)][object]$PriorityPolicy,
    [Parameter(Mandatory)][object]$BranchPolicy,
    [Parameter(Mandatory)][string[]]$Candidates,
    [AllowNull()][string]$FallbackBranchName
  )

  foreach ($candidate in $Candidates) {
    $rulesetNode = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PriorityPolicy -Name 'rulesets') -Name $candidate
    if ($null -eq $rulesetNode) {
      continue
    }

    $explicitChecks = @(Normalize-CheckList -Value (Get-ObjectPropertyValue -Object $rulesetNode -Name 'required_status_checks'))
    if ($explicitChecks.Count -gt 0) {
      return $explicitChecks
    }

    $branchName = $FallbackBranchName
    foreach ($include in @((Get-ObjectPropertyValue -Object $rulesetNode -Name 'includes'))) {
      if ([string]::IsNullOrWhiteSpace([string]$include) -or -not ([string]$include).StartsWith('refs/heads/')) {
        continue
      }
      $normalized = ([string]$include).Substring('refs/heads/'.Length)
      if (-not [string]::IsNullOrWhiteSpace($branchName) -and $branchName -ne $normalized) {
        throw "Ruleset '$candidate' includes multiple branch refs ('$branchName' and '$normalized'); required-check projection must remain single-branch."
      }
      $branchName = $normalized
    }

    return @((Resolve-BranchRequiredCheckProjection -BranchPolicy $BranchPolicy -BranchName $branchName -BranchClassId ([string](Get-ObjectPropertyValue -Object $rulesetNode -Name 'branch_class_id'))).requiredChecks)
  }

  return @()
}

function Resolve-PromotionContractRequiredChecks {
  param(
    [Parameter(Mandatory)][object]$Contract,
    [Parameter(Mandatory)][object]$BranchPolicy,
    [Parameter(Mandatory)][string]$BranchName
  )

  $legacyChecks = @(Normalize-CheckList -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Contract -Name 'required_status_checks') -Name $BranchName))
  if ($legacyChecks.Count -gt 0) {
    return $legacyChecks
  }

  $referenceNode = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Contract -Name 'required_status_checks_ref') -Name $BranchName
  if ($null -eq $referenceNode) {
    return @()
  }

  if ($referenceNode -is [string]) {
    return @((Resolve-BranchRequiredCheckProjection -BranchPolicy $BranchPolicy -BranchName ([string]$referenceNode) -BranchClassId $null).requiredChecks)
  }

  $targetBranchName = if ($null -ne (Get-ObjectPropertyValue -Object $referenceNode -Name 'branchName')) {
    [string](Get-ObjectPropertyValue -Object $referenceNode -Name 'branchName')
  } else {
    $BranchName
  }
  $targetBranchClassId = if ($null -ne (Get-ObjectPropertyValue -Object $referenceNode -Name 'branchClassId')) {
    [string](Get-ObjectPropertyValue -Object $referenceNode -Name 'branchClassId')
  } else {
    $null
  }

  return @(
    (Resolve-BranchRequiredCheckProjection -BranchPolicy $BranchPolicy -BranchName $targetBranchName -BranchClassId $targetBranchClassId).requiredChecks
  )
}

Export-ModuleMember -Function `
  Resolve-BranchRequiredCheckProjection, `
  Resolve-PriorityPolicyBranchRequiredChecks, `
  Resolve-PriorityPolicyRulesetRequiredChecks, `
  Resolve-PromotionContractRequiredChecks, `
  Normalize-CheckList
