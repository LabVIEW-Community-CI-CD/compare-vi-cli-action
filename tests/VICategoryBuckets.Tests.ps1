Describe 'VICategoryBuckets module' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $modulePath = Join-Path $repoRoot 'tools' 'VICategoryBuckets.psm1'
        Import-Module $modulePath -Force
    }

    It 'maps VI Attribute to metadata bucket' {
        $meta = Get-VICategoryMetadata -Name 'VI Attribute'
        $meta | Should -Not -BeNullOrEmpty
        $meta.slug | Should -Be 'vi-attribute'
        $meta.bucketSlug | Should -Be 'metadata'
        $meta.bucketLabel | Should -Be 'Metadata'
        $meta.bucketClassification | Should -Be 'neutral'
    }

    It 'preserves known slug inputs without degrading category specificity' {
        $meta = Get-VICategoryMetadata -Name 'block-diagram-cosmetic'
        $meta | Should -Not -BeNullOrEmpty
        $meta.slug | Should -Be 'block-diagram-cosmetic'
        $meta.label | Should -Be 'Block diagram (cosmetic)'
        $meta.bucketSlug | Should -Be 'ui-visual'
    }

    It 'collects bucket details for multiple categories' {
        $inputCategories = @(
            'Block Diagram Functional',
            'Front Panel Position/Size',
            'Documentation'
        )

        $info = Get-VICategoryBuckets -Names $inputCategories
        $info | Should -Not -BeNullOrEmpty
        $info.Details.Count | Should -Be 3
        $info.BucketSlugs | Should -Contain 'functional-behavior'
        $info.BucketSlugs | Should -Contain 'ui-visual'
        $info.BucketSlugs | Should -Contain 'metadata'

        $functionalBucket = $info.BucketDetails | Where-Object { $_.slug -eq 'functional-behavior' }
        $functionalBucket | Should -Not -BeNullOrEmpty
        $functionalBucket.label | Should -Be 'Functional behavior'
        $functionalBucket.classification | Should -Be 'signal'
    }
}
