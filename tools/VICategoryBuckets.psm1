#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BucketDefinitions = @{
    'functional-behavior' = @{
        label          = 'Functional behavior'
        classification = 'signal'
    }
    'ui-visual' = @{
        label          = 'UI / visual'
        classification = 'noise'
    }
    'metadata' = @{
        label          = 'Metadata'
        classification = 'neutral'
    }
    'uncategorized' = @{
        label          = 'Uncategorized'
        classification = 'neutral'
    }
}

$script:CategoryDefinitions = @{
    'block-diagram' = @{
        label          = 'Block diagram'
        classification = 'signal'
        bucket         = 'functional-behavior'
    }
    'block-diagram-functional' = @{
        label          = 'Block diagram (functional)'
        classification = 'signal'
        bucket         = 'functional-behavior'
    }
    'block-diagram-cosmetic' = @{
        label          = 'Block diagram (cosmetic)'
        classification = 'noise'
        bucket         = 'ui-visual'
    }
    'connector-pane' = @{
        label          = 'Connector pane'
        classification = 'signal'
        bucket         = 'functional-behavior'
    }
    'front-panel' = @{
        label          = 'Front panel'
        classification = 'signal'
        bucket         = 'ui-visual'
    }
    'front-panel-position-size' = @{
        label          = 'Front panel position/size'
        classification = 'noise'
        bucket         = 'ui-visual'
    }
    'control-changes' = @{
        label          = 'Front panel controls'
        classification = 'signal'
        bucket         = 'ui-visual'
    }
    'window' = @{
        label          = 'Window properties'
        classification = 'neutral'
        bucket         = 'ui-visual'
    }
    'icon' = @{
        label          = 'Icon'
        classification = 'noise'
        bucket         = 'ui-visual'
    }
    'attributes' = @{
        label          = 'Attributes'
        classification = 'neutral'
        bucket         = 'metadata'
    }
    'vi-attribute' = @{
        label          = 'VI attribute'
        classification = 'neutral'
        bucket         = 'metadata'
    }
    'documentation' = @{
        label          = 'Documentation'
        classification = 'neutral'
        bucket         = 'metadata'
    }
    'execution' = @{
        label          = 'Execution settings'
        classification = 'signal'
        bucket         = 'functional-behavior'
    }
    'unspecified' = @{
        label          = 'Unspecified'
        classification = 'neutral'
        bucket         = 'uncategorized'
    }
    'cosmetic' = @{
        label          = 'Cosmetic'
        classification = 'noise'
        bucket         = 'ui-visual'
    }
}

function Resolve-VICategorySlug {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $token = $Name.Trim().ToLowerInvariant()
    if ($script:CategoryDefinitions.ContainsKey($token)) { return $token }
    $normalizedToken = $token -replace '[-_]+', ' '

    if ($normalizedToken -match 'block diagram' -and $normalizedToken -match 'cosmetic') { return 'block-diagram-cosmetic' }
    if ($normalizedToken -match 'block diagram' -and $normalizedToken -match 'functional') { return 'block-diagram-functional' }
    if ($normalizedToken -match 'block diagram') { return 'block-diagram' }
    if ($normalizedToken -match 'connector') { return 'connector-pane' }
    if ($normalizedToken -match 'vi attribute' -or $normalizedToken -match 'attributes') { return 'vi-attribute' }
    if ($normalizedToken -match 'front panel position') { return 'front-panel-position-size' }
    if ($normalizedToken -match 'front panel' -or $normalizedToken -match 'control changes') { return 'front-panel' }
    if ($normalizedToken -match 'cosmetic') { return 'cosmetic' }
    if ($normalizedToken -match 'window') { return 'window' }
    if ($normalizedToken -match 'icon') { return 'icon' }
    if ($normalizedToken -match 'documentation') { return 'documentation' }
    if ($normalizedToken -match 'execution') { return 'execution' }

    return ($token -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-VIBucketMetadata {
    param([string]$BucketSlug)

    $slug = if ([string]::IsNullOrWhiteSpace($BucketSlug)) { 'uncategorized' } else { $BucketSlug.Trim().ToLowerInvariant() }
    if (-not $script:BucketDefinitions.ContainsKey($slug)) {
        $slug = 'uncategorized'
    }
    $definition = $script:BucketDefinitions[$slug]
    return [pscustomobject]@{
        slug           = $slug
        label          = $definition.label
        classification = $definition.classification
    }
}

function Get-VICategoryMetadata {
    param([string]$Name)

    $slug = Resolve-VICategorySlug -Name $Name
    if (-not $slug) { return $null }

    $definition = $script:CategoryDefinitions[$slug]
    $label = $null
    $classification = 'signal'
    $bucketSlug = 'uncategorized'
    if ($definition) {
        $label = $definition.label
        $classification = $definition.classification
        $bucketSlug = $definition.bucket
    } else {
        $spaced = ($slug -replace '[-_]', ' ')
        $label = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($spaced)
    }

    $bucket = Get-VIBucketMetadata -BucketSlug $bucketSlug

    return [pscustomobject]@{
        slug                = $slug
        label               = $label
        classification      = $classification
        bucketSlug          = $bucket.slug
        bucketLabel         = $bucket.label
        bucketClassification= $bucket.classification
    }
}

function ConvertTo-VICategoryDetails {
    param([System.Collections.IEnumerable]$Names)

    $details = [System.Collections.Generic.List[object]]::new()
    if (-not $Names) { return @() }

    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $meta = Get-VICategoryMetadata -Name $name
        if (-not $meta) { continue }
        if ($seen.Add($meta.slug)) {
            $details.Add($meta) | Out-Null
        }
    }

    return @($details)
}

function Get-VICategoryBuckets {
    param([System.Collections.IEnumerable]$Names)

    $details = ConvertTo-VICategoryDetails -Names $Names
    $bucketSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $bucketDetails = [System.Collections.Generic.List[object]]::new()
    foreach ($detail in $details) {
        if (-not $detail) { continue }
        if (-not [string]::IsNullOrWhiteSpace($detail.bucketSlug)) {
            $bucketSet.Add($detail.bucketSlug) | Out-Null
            $bucketMeta = Get-VIBucketMetadata -BucketSlug $detail.bucketSlug
            if ($bucketMeta -and -not ($bucketDetails | Where-Object { $_.slug -eq $bucketMeta.slug })) {
                $bucketDetails.Add($bucketMeta) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        Details       = $details
        BucketSlugs   = @($bucketSet)
        BucketDetails = @($bucketDetails)
    }
}

Export-ModuleMember -Function Resolve-VICategorySlug, Get-VIBucketMetadata, Get-VICategoryMetadata, ConvertTo-VICategoryDetails, Get-VICategoryBuckets
