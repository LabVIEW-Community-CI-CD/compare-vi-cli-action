#Requires -Version 7.0
#Requires -Modules Pester

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'VIPM CLI smoke coverage' -Tag 'Vipm','Tooling','Integration' {
    BeforeAll {
        $script:vipmCommand = Get-Command vipm -ErrorAction Stop
    }

    It 'reports CLI version metadata' {
        $output = & $script:vipmCommand.Source '--version' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match '^vipm\s+\d+\.\d+\.\d+'
    }

    It 'documents build command flags from official help' {
        $output = & $script:vipmCommand.Source 'build' '--help' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Builds project artifacts'
        $output | Should -Match '--lvproj-spec'
        $output | Should -Match '<BUILD_SPEC>'
    }

    It 'lists top-level subcommands with vipm help' {
        $output = & $script:vipmCommand.Source 'help' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        foreach ($cmd in @('install','build','list','search','uninstall')) {
            $output | Should -Match ("(?m)^\s+{0}\s" -f $cmd)
        }
    }

    It 'provides list subcommand usage' {
        $output = & $script:vipmCommand.Source 'list' '--help' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Lists packages'
        $output | Should -Match '--installed'
    }

    It 'provides install/uninstall subcommand usage' {
        $installHelp = & $script:vipmCommand.Source 'install' '--help' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $installHelp | Should -Match 'Installs one or more packages'

        $uninstallHelp = & $script:vipmCommand.Source 'uninstall' '--help' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $uninstallHelp | Should -Match 'Uninstalls one or more packages'
    }

    It 'enumerates installed packages for LabVIEW 2026 64-bit' -Tag 'VipmSlow' {
        $output = & $script:vipmCommand.Source 'list' '--installed' '--labview-version' '2026' '--labview-bitness' '64' '--color-mode' 'never' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'Using LabVIEW 2026 \(64-bit\)'
        $output | Should -Match 'Found \d+ packages'
    }

    It 'handles repeated list --installed invocations for stability' -Tag 'VipmSlow' {
        $output1 = & $script:vipmCommand.Source 'list' '--installed' '--labview-version' '2026' '--labview-bitness' '64' '--color-mode' 'never' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output2 = & $script:vipmCommand.Source 'list' '--installed' '--labview-version' '2026' '--labview-bitness' '64' '--color-mode' 'never' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0

        $countPattern = 'Found\s+(?<count>\d+)\s+packages'
        $output1 | Should -Match $countPattern
        $output2 | Should -Match $countPattern
        $matches1 = [regex]::Match($output1, $countPattern)
        $matches2 = [regex]::Match($output2, $countPattern)
        [int]$matches1.Groups['count'].Value | Should -Be ([int]$matches2.Groups['count'].Value)
    }
}
