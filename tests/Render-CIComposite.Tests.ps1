$ErrorActionPreference = 'Stop'

Describe 'render-ci-composite.ps1' -Tag 'Workflows','Templates' {
    BeforeAll {
        $sourceScript = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'tools/workflows/render-ci-composite.ps1'
        $sourceTemplate = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'tools/workflows/templates/ci-composite.yml.tmpl'
        Set-Variable -Scope Script -Name SourceScript -Value $sourceScript
        Set-Variable -Scope Script -Name SourceTemplate -Value $sourceTemplate
    }

    It 'throws when the ci-composite template is missing' {
        $repoRoot = Join-Path $TestDrive 'missing-template'
        $workflowsRoot = Join-Path $repoRoot 'tools/workflows'
        New-Item -ItemType Directory -Path $workflowsRoot -Force | Out-Null
        $scriptCopy = Join-Path $workflowsRoot 'render-ci-composite.ps1'
        Copy-Item -LiteralPath $script:SourceScript -Destination $scriptCopy
        New-Item -ItemType Directory -Path (Join-Path $repoRoot '.github/workflows') -Force | Out-Null

        $arguments = @(
            '-NoLogo',
            '-NoProfile',
            '-File', $scriptCopy,
            '-RenderVendor:$false'
        )
        $output = & pwsh @arguments 2>&1
        ($output -join "`n") | Should -Match 'Template not found'
    }

    It 'renders the root workflow when the template is present' {
        $repoRoot = Join-Path $TestDrive 'render-root'
        $workflowsRoot = Join-Path $repoRoot 'tools/workflows'
        New-Item -ItemType Directory -Path $workflowsRoot -Force | Out-Null
        $templatesRoot = Join-Path $workflowsRoot 'templates'
        New-Item -ItemType Directory -Path $templatesRoot -Force | Out-Null
        Copy-Item -LiteralPath $script:SourceScript -Destination (Join-Path $workflowsRoot 'render-ci-composite.ps1')
        Copy-Item -LiteralPath $script:SourceTemplate -Destination (Join-Path $templatesRoot 'ci-composite.yml.tmpl')
        New-Item -ItemType Directory -Path (Join-Path $repoRoot '.github/workflows') -Force | Out-Null

        $scriptCopy = Join-Path $workflowsRoot 'render-ci-composite.ps1'
        pwsh -NoLogo -NoProfile -File $scriptCopy -RenderVendor:$false

        $outputPath = Join-Path $repoRoot '.github/workflows/ci-composite.yml'
        Test-Path -LiteralPath $outputPath -PathType Leaf | Should -BeTrue
        $content = Get-Content -LiteralPath $outputPath -Raw
        $content | Should -Match 'build-vi-package'
        $content | Should -Match 'apply-deps'
    }

    It 'renders the vendor workflow when requested' {
        $repoRoot = Join-Path $TestDrive 'render-vendor'
        $workflowsRoot = Join-Path $repoRoot 'tools/workflows'
        New-Item -ItemType Directory -Path $workflowsRoot -Force | Out-Null
        $templatesRoot = Join-Path $workflowsRoot 'templates'
        New-Item -ItemType Directory -Path $templatesRoot -Force | Out-Null
        Copy-Item -LiteralPath $script:SourceScript -Destination (Join-Path $workflowsRoot 'render-ci-composite.ps1')
        Copy-Item -LiteralPath $script:SourceTemplate -Destination (Join-Path $templatesRoot 'ci-composite.yml.tmpl')
        New-Item -ItemType Directory -Path (Join-Path $repoRoot '.github/workflows') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repoRoot 'vendor/icon-editor/.github/workflows') -Force | Out-Null

        $scriptCopy = Join-Path $workflowsRoot 'render-ci-composite.ps1'
        pwsh -NoLogo -NoProfile -File $scriptCopy

        $vendorPath = Join-Path $repoRoot 'vendor/icon-editor/.github/workflows/ci-composite.yml'
        Test-Path -LiteralPath $vendorPath -PathType Leaf | Should -BeTrue
        $vendorContent = Get-Content -LiteralPath $vendorPath -Raw
        $vendorContent | Should -Match 'self-hosted-windows-lv'
        $vendorContent | Should -Match 'build-ppl'
    }
}
