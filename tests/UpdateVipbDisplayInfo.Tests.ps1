#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Update-VipbDisplayInfo.ps1' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:ScriptPath = Join-Path $RepoRoot '.github\actions\modify-vipb-display-info\Update-VipbDisplayInfo.ps1'
        $script:FixtureVipb = Join-Path $RepoRoot '.github\actions\build-vi-package\NI Icon editor.vipb'

        if (-not (Test-Path -LiteralPath $script:ScriptPath -PathType Leaf)) {
            throw "Update-VipbDisplayInfo.ps1 not found at '$ScriptPath'."
        }

        $originalDoc = New-Object System.Xml.XmlDocument
        $originalDoc.PreserveWhitespace = $true
        $originalDoc.Load($script:FixtureVipb)
        $script:OriginalXml = $originalDoc
    }

    BeforeEach {
        $contextDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $contextDir | Out-Null

        $vipbCopyPath = Join-Path $contextDir 'spec-under-test.vipb'
        Copy-Item -LiteralPath $script:FixtureVipb -Destination $vipbCopyPath -Force

        $releaseNotesRelative = 'release_notes.md'
        $displayPayload = @{
            'Package Version' = @{
                major = 9
                minor = 8
                patch = 7
                build = 6
            }
            'Product Name'                   = 'Injected Product'
            'Company Name'                   = 'Injected Co'
            'Author Name (Person or Company)'= 'Injected Author'
            'Product Description Summary'    = 'Summary text'
            'Product Description'            = 'Full description'
            'Release Notes - Change Log'     = 'Release notes text'
            'Product Homepage (URL)'         = 'https://example.test'
            'Legal Copyright'                = 'Copyright 2025'
            'License Agreement Name'         = 'Custom License'
        } | ConvertTo-Json -Depth 5

        & $script:ScriptPath `
            -MinimumSupportedLVVersion 2023 `
            -LabVIEWMinorRevision 3 `
            -SupportedBitness 64 `
            -Major 9 `
            -Minor 8 `
            -Patch 7 `
            -Build 6 `
            -Commit 'commit-hash' `
            -IconEditorRoot $contextDir `
            -VIPBPath (Split-Path -Leaf $vipbCopyPath) `
            -ReleaseNotesFile $releaseNotesRelative `
            -DisplayInformationJSON $displayPayload

        $script:UpdatedDoc = New-Object System.Xml.XmlDocument
        $script:UpdatedDoc.PreserveWhitespace = $true
        $script:UpdatedDoc.Load($vipbCopyPath)
        $script:UpdatedRoot = $script:UpdatedDoc.VI_Package_Builder_Settings
        $script:UpdatedDescription = $script:UpdatedRoot.Advanced_Settings.Description
        $script:ReleaseNotesPath = Join-Path $contextDir $releaseNotesRelative
        $script:VipbCopyPath = $vipbCopyPath
    }

    AfterEach {
        Remove-Item -LiteralPath $script:VipbCopyPath -ErrorAction SilentlyContinue
    }

    Context 'Library general settings' {
        It 'updates company name' {
            $script:UpdatedRoot.Library_General_Settings.Company_Name | Should -Be 'INJECTED CO'
        }

        It 'updates product name' {
            $script:UpdatedRoot.Library_General_Settings.Product_Name | Should -Be 'Injected Product'
        }

        It 'updates summary' {
            $script:UpdatedRoot.Library_General_Settings.Library_Summary | Should -Be 'Summary text'
        }

        It 'updates license' {
            $script:UpdatedRoot.Library_General_Settings.Library_License | Should -Be 'Custom License'
        }

        It 'updates version' {
            $script:UpdatedRoot.Library_General_Settings.Library_Version | Should -Be '9.8.7.6'
        }

        It 'updates LabVIEW target' {
            $script:UpdatedRoot.Library_General_Settings.Package_LabVIEW_Version | Should -Be '23.3 (64-bit)'
        }
    }

    Context 'Advanced description fields' {
        It 'updates summary mirror' {
            $script:UpdatedDescription.One_Line_Description_Summary | Should -Be 'Summary text'
        }

        It 'updates product description' {
            $script:UpdatedDescription.Description | Should -Be 'Full description'
        }

        It 'updates release notes text' {
            $script:UpdatedDescription.Release_Notes | Should -Be 'Release notes text'
        }

        It 'updates packager name' {
            $script:UpdatedDescription.Packager | Should -Be 'INJECTED AUTHOR'
        }

        It 'updates website url' {
            $script:UpdatedDescription.URL | Should -Be 'https://example.test'
        }

        It 'updates copyright' {
            $script:UpdatedDescription.Copyright | Should -Be 'Copyright 2025'
        }
    }

    Context 'Ancillary updates' {
        It 'updates configuration file name' {
            $script:UpdatedRoot.Advanced_Settings.VI_Package_Configuration_File | Should -Be 'spec-under-test.vipc'
        }

        It 'regenerates ID and Modified date' {
            $script:UpdatedRoot.GetAttribute('ID') | Should -Not -Be $script:OriginalXml.VI_Package_Builder_Settings.GetAttribute('ID')
            $script:UpdatedRoot.GetAttribute('Modified_Date') | Should -Not -Be $script:OriginalXml.VI_Package_Builder_Settings.GetAttribute('Modified_Date')
        }

        It 'creates release notes file' {
            Test-Path $script:ReleaseNotesPath | Should -BeTrue
        }
    }

    It 'touches only the targeted nodes' {
        $updatedDoc = $script:UpdatedDoc

        function Reset-NodeValue {
            param(
                [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
                [Parameter(Mandatory)][System.Xml.XmlDocument]$Baseline,
                [Parameter(Mandatory)][string]$XPath
            )
            $baselineNode = $Baseline.SelectSingleNode($XPath)
            $target = $Document.SelectSingleNode($XPath)
            if (-not $baselineNode -or -not $target) { return }

            $parent = $target.ParentNode
            if (-not $parent) { return }

            $imported = $Document.ImportNode($baselineNode, $true)
            $parent.ReplaceChild($imported, $target) | Out-Null
        }

        $sanitized = New-Object System.Xml.XmlDocument
        $sanitized.PreserveWhitespace = $true
        $sanitized.LoadXml($UpdatedDoc.OuterXml)

        $pathsToRestore = @(
            '/VI_Package_Builder_Settings/Library_General_Settings/Product_Name',
            '/VI_Package_Builder_Settings/Library_General_Settings/Company_Name',
            '/VI_Package_Builder_Settings/Library_General_Settings/Library_Summary',
            '/VI_Package_Builder_Settings/Library_General_Settings/Library_License',
            '/VI_Package_Builder_Settings/Library_General_Settings/Library_Version',
            '/VI_Package_Builder_Settings/Library_General_Settings/Package_LabVIEW_Version',
            '/VI_Package_Builder_Settings/Advanced_Settings/Description/One_Line_Description_Summary',
            '/VI_Package_Builder_Settings/Advanced_Settings/Description/Description',
            '/VI_Package_Builder_Settings/Advanced_Settings/Description/Release_Notes',
            '/VI_Package_Builder_Settings/Advanced_Settings/Description/Packager',
            '/VI_Package_Builder_Settings/Advanced_Settings/Description/URL',
            '/VI_Package_Builder_Settings/Advanced_Settings/Description/Copyright',
            '/VI_Package_Builder_Settings/Advanced_Settings/VI_Package_Configuration_File'
        )

        foreach ($path in $pathsToRestore) {
            Reset-NodeValue -Document $sanitized -Baseline $OriginalXml -XPath $path
        }

        $sanitized.DocumentElement.SetAttribute('ID', $script:OriginalXml.DocumentElement.GetAttribute('ID'))
        $sanitized.DocumentElement.SetAttribute('Modified_Date', $script:OriginalXml.DocumentElement.GetAttribute('Modified_Date'))

        $sanitized.OuterXml | Should -Be $script:OriginalXml.OuterXml
    }
}
