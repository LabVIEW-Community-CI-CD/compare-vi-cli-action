$ErrorActionPreference = 'Stop'

Describe 'Close-LabVIEW.ps1' -Tag 'IconEditor','GCli','CloseLabVIEW' {
    BeforeAll {
        $script:repoRootActual = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:closeScript = Join-Path $script:repoRootActual 'vendor/icon-editor/.github/actions/close-labview/Close_LabVIEW.ps1'
        Test-Path -LiteralPath $script:closeScript | Should -BeTrue
        Import-Module (Join-Path $script:repoRootActual 'tools/VendorTools.psm1') -Force
    }

    function Script:Initialize-CliRecorder {
        $script:cliLogPath = Join-Path $TestDrive ("cli-log-{0}.txt" -f ([guid]::NewGuid().ToString('n')))
        New-Item -ItemType File -Path $script:cliLogPath -Force | Out-Null

        $script:cliStubPath = Join-Path $TestDrive ("cli-stub-{0}.ps1" -f ([guid]::NewGuid().ToString('n')))
@'
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$parts = @()
if ($Args) { $parts += $Args }

$logPath = $env:GCLI_LOG
if ([string]::IsNullOrWhiteSpace($logPath)) {
    $logPath = Join-Path $env:TEMP 'g-cli-stub.log'
}
Add-Content -LiteralPath $logPath -Value ($parts -join ' ')

$exitCode = 0
if (-not [string]::IsNullOrWhiteSpace($env:GCLI_EXIT_CODE)) {
    [void][int]::TryParse($env:GCLI_EXIT_CODE, [ref]$exitCode)
}
exit $exitCode
'@ | Set-Content -LiteralPath $script:cliStubPath -Encoding UTF8

        $env:GCLI_LOG = $script:cliLogPath
        $env:GCLI_EXE_PATH = $script:cliStubPath
    }

    BeforeEach {
        Remove-Item Env:GCLI_EXIT_CODE -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:LABVIEW_PROCESS_MOCK_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:LABVIEW_PROCESS_KILL_LOG -ErrorAction SilentlyContinue
        Initialize-CliRecorder
    }

    AfterEach {
        Remove-Item Env:GCLI_EXIT_CODE -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:LABVIEW_PROCESS_MOCK_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:LABVIEW_PROCESS_KILL_LOG -ErrorAction SilentlyContinue
        if ($script:cliLogPath -and (Test-Path -LiteralPath $script:cliLogPath)) {
            Remove-Item -LiteralPath $script:cliLogPath -Force
        }
        if ($script:cliStubPath -and (Test-Path -LiteralPath $script:cliStubPath)) {
            Remove-Item -LiteralPath $script:cliStubPath -Force
        }
    }

    It 'invokes g-cli kill without using fallback when CLI succeeds' {
        $env:GCLI_EXIT_CODE = '0'

        & $script:closeScript -MinimumSupportedLVVersion 2023 -SupportedBitness 32

        $logLines = Get-Content -LiteralPath $script:cliLogPath
        if ($logLines -is [string]) { $logLines = @($logLines) }
        $logLines | Should -HaveCount 1
        ($logLines[0].Contains('--kill')) | Should -BeTrue
        ($logLines[0].Contains('--lv-ver')) | Should -BeTrue
        ($logLines[0].Contains('2023')) | Should -BeTrue
        ($logLines[0].Contains('--arch')) | Should -BeTrue
        ($logLines[0].Contains('32')) | Should -BeTrue
    }

    It 'falls back to terminating only matching LabVIEW processes when g-cli fails' {
        $env:GCLI_EXIT_CODE = '1'

        $targetExe = Resolve-LabVIEWExePath -Version 2023 -Bitness 32
        $targetExe | Should -Not -BeNullOrEmpty

        $processMockPath = Join-Path $TestDrive 'process-list.json'
        $killLogPath = Join-Path $TestDrive 'kill-log.json'
        $processList = @(
            [ordered]@{ Id = 111; Path = $targetExe; ProcessName = 'LabVIEW' },
            [ordered]@{ Id = 222; Path = 'C:/Other/LabVIEW.exe'; ProcessName = 'LabVIEW' }
        )
        $processList | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $processMockPath -Encoding UTF8
        $env:LABVIEW_PROCESS_MOCK_PATH = $processMockPath
        $env:LABVIEW_PROCESS_KILL_LOG = $killLogPath

        { & $script:closeScript -MinimumSupportedLVVersion 2023 -SupportedBitness 32 } | Should -Not -Throw

        $killEntries = if (Test-Path -LiteralPath $killLogPath) {
            Get-Content -LiteralPath $killLogPath -Raw | ConvertFrom-Json -Depth 5
        } else {
            @()
        }
        if ($killEntries -and $killEntries -isnot [System.Collections.IEnumerable]) {
            $killEntries = @($killEntries)
        }
        $killEntries | Should -HaveCount 1
        $killEntries[0].id | Should -Be 111
        $killEntries[0].path | Should -Be $targetExe

        $logLines = Get-Content -LiteralPath $script:cliLogPath
        if ($logLines -is [string]) { $logLines = @($logLines) }
        $logLines | Should -HaveCount 1
        ($logLines[0].Contains('--kill')) | Should -BeTrue
    }
}
