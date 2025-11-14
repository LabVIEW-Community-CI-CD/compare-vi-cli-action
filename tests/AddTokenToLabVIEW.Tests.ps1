$ErrorActionPreference = 'Stop'

Describe 'AddTokenToLabVIEW.ps1' -Tag 'IconEditor','GCli','AddToken' {
    BeforeAll {
        $script:repoRootActual = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:addTokenScript = Join-Path $script:repoRootActual 'vendor/icon-editor/.github/actions/add-token-to-labview/AddTokenToLabVIEW.ps1'
        Test-Path -LiteralPath $script:addTokenScript | Should -BeTrue
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

    function Script:Initialize-FixtureDirectories {
        param([string]$RepoRoot)

        $deploymentRoot = Join-Path $RepoRoot 'Tooling/deployment'
        New-Item -ItemType Directory -Path $deploymentRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $deploymentRoot 'Create_LV_INI_Token.vi') -Value '' -Encoding ascii
    }

    BeforeEach {
        Initialize-CliRecorder
        Remove-Item Env:GCLI_EXIT_CODE -ErrorAction SilentlyContinue

        $script:closeLogPath = Join-Path $TestDrive ("close-log-{0}.txt" -f ([guid]::NewGuid().ToString('n')))
        New-Item -ItemType File -Path $script:closeLogPath -Force | Out-Null
        $script:closeStubPath = Join-Path $TestDrive ("close-stub-{0}.ps1" -f ([guid]::NewGuid().ToString('n')))
@'
[CmdletBinding()]
param(
    [string]$MinimumSupportedLVVersion,
    [string]$SupportedBitness
)
$logPath = if ($env:ICON_EDITOR_CLOSE_LOG) { $env:ICON_EDITOR_CLOSE_LOG } else { Join-Path $env:TEMP 'close-lv-stub.log' }
$line = "close:${MinimumSupportedLVVersion}:${SupportedBitness}"
Add-Content -LiteralPath $logPath -Value $line
'@ | Set-Content -LiteralPath $script:closeStubPath -Encoding utf8
        $env:ICON_EDITOR_CLOSE_LOG = $script:closeLogPath
        $env:ICON_EDITOR_CLOSE_SCRIPT_PATH = $script:closeStubPath
    }

    AfterEach {
        Remove-Item Env:GCLI_EXIT_CODE -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:ICON_EDITOR_CLOSE_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:ICON_EDITOR_CLOSE_SCRIPT_PATH -ErrorAction SilentlyContinue
        if ($script:cliLogPath -and (Test-Path -LiteralPath $script:cliLogPath)) {
            Remove-Item -LiteralPath $script:cliLogPath -Force
        }
        if ($script:cliStubPath -and (Test-Path -LiteralPath $script:cliStubPath)) {
            Remove-Item -LiteralPath $script:cliStubPath -Force
        }
        if ($script:closeStubPath -and (Test-Path -LiteralPath $script:closeStubPath)) {
            Remove-Item -LiteralPath $script:closeStubPath -Force
        }
        if ($script:closeLogPath -and (Test-Path -LiteralPath $script:closeLogPath)) {
            Remove-Item -LiteralPath $script:closeLogPath -Force
        }
    }

    It 'invokes g-cli with expected parameters' {
        $iconRepo = Join-Path $TestDrive 'icon-editor'
        Initialize-FixtureDirectories -RepoRoot $iconRepo

        $env:GCLI_EXIT_CODE = '0'

        & $script:addTokenScript `
            -MinimumSupportedLVVersion 2023 `
            -SupportedBitness 32 `
            -IconEditorRoot $iconRepo

        $logLines = Get-Content -LiteralPath $script:cliLogPath
        if ($logLines -is [string]) { $logLines = @($logLines) }
        $logLines | Should -HaveCount 1

        $firstLine = $logLines[0]
        ($firstLine.Contains('--lv-ver')) | Should -BeTrue
        ($firstLine.Contains('2023')) | Should -BeTrue
        ($firstLine.Contains('--arch')) | Should -BeTrue
        ($firstLine.Contains('32')) | Should -BeTrue
        ($firstLine.Contains('Create_LV_INI_Token.vi')) | Should -BeTrue
        ($firstLine.Contains('Localhost.LibraryPaths')) | Should -BeTrue
        ($firstLine.Contains($iconRepo)) | Should -BeTrue
        ($firstLine.Contains(' -- LabVIEW')) | Should -BeTrue

        $closeEntries = Get-Content -LiteralPath $script:closeLogPath
        if ($closeEntries -is [string]) { $closeEntries = @($closeEntries) }
        $closeEntries | Should -HaveCount 1
        $closeEntries[0] | Should -Be 'close:2023:32'
    }

    It 'throws when g-cli reports a non-zero exit code' {
        $iconRepo = Join-Path $TestDrive 'icon-editor-error'
        Initialize-FixtureDirectories -RepoRoot $iconRepo

        $env:GCLI_EXIT_CODE = '1'

        {
            & $script:addTokenScript `
                -MinimumSupportedLVVersion 2023 `
                -SupportedBitness 32 `
                -IconEditorRoot $iconRepo
        } | Should -Throw -ErrorId *

        $logLines = Get-Content -LiteralPath $script:cliLogPath
        if ($logLines -is [string]) { $logLines = @($logLines) }
        $logLines | Should -HaveCount 1
        ($logLines[0].Contains(' -- LabVIEW')) | Should -BeTrue

        if (Test-Path -LiteralPath $script:closeLogPath) {
            $closeEntries = Get-Content -LiteralPath $script:closeLogPath
            if ($closeEntries -is [string]) { $closeEntries = @($closeEntries) }
            ($closeEntries | Where-Object { $_ }) | Should -HaveCount 0
        }
    }
}
