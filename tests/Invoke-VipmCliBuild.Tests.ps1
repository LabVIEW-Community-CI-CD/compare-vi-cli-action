#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Invoke-VipmCliBuild' -Tag 'IconEditor','Unit' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'icon-editor' 'Invoke-VipmCliBuild.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Unable to locate Invoke-VipmCliBuild.ps1 at '$script:scriptPath'."
        }
    }

    BeforeEach {
        $script:pwshCallLog = New-Object System.Collections.Generic.List[object]
        Set-Variable -Name pwshCallLog -Scope Global -Value $script:pwshCallLog

        function global:pwsh {
            param(
                [Parameter(ValueFromRemainingArguments = $true)]
                [object[]]$ArgumentList
            )

            $global:LASTEXITCODE = 0
            $null = $global:pwshCallLog.Add($ArgumentList)
        }
    }

    AfterEach {
        if (Get-Command pwsh -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path function:\pwsh -Force
        }
        if (Get-Variable -Name pwshCallLog -Scope Global -ErrorAction SilentlyContinue) {
            Remove-Variable -Name pwshCallLog -Scope Global -Force
        }
        $script:pwshCallLog.Clear()
    }

    It 'invokes ApplyVIPC with the packaging LabVIEW version (2026 x64)' {
        $resultsRoot = Join-Path $TestDrive 'results'
        New-Item -ItemType Directory -Path $resultsRoot | Out-Null

        & $script:scriptPath `
            -RepoRoot $script:repoRoot `
            -SkipSync `
            -SkipBuild `
            -SkipRogueCheck `
            -SkipClose `
            -ResultsRoot $resultsRoot `
            -PackageMinimumSupportedLVVersion 2026 `
            -PackageSupportedBitness 64 | Out-Null

        $applyCalls = $script:pwshCallLog | Where-Object {
            $_ -and ($_ | Where-Object { $_ -is [string] -and $_ -like '*ApplyVIPC.ps1' })
        }

        $applyCalls.Count | Should -BeGreaterOrEqual 1

        $packagingCall = $applyCalls | Where-Object {
            $args = $_
            $argumentMap = [ordered]@{}
            for ($index = 0; $index -lt $args.Count; $index++) {
                $token = $args[$index]
                if ($token -isnot [string]) { continue }
                if ($token -notmatch '^-') { continue }

                $value = $true
                if ($index -lt ($args.Count - 1)) {
                    $next = $args[$index + 1]
                    if ($next -is [string] -and $next -notmatch '^-') {
                        $value = $next
                        $index++
                    }
                }

                $argumentMap[$token] = $value
            }

            ($argumentMap['-VIP_LVVersion'] -eq '2026') -and
            ($argumentMap['-SupportedBitness'] -eq '64')
        }

        $packagingCall | Should -Not -BeNullOrEmpty
    }
}
