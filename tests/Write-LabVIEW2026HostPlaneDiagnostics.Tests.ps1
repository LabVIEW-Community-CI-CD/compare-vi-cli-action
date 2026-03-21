#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-LabVIEW2026HostPlaneDiagnostics.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:DiagnosticsScript = Join-Path $repoRoot 'tools' 'Write-LabVIEW2026HostPlaneDiagnostics.ps1'
    if (-not (Test-Path -LiteralPath $script:DiagnosticsScript -PathType Leaf)) {
      throw "Write-LabVIEW2026HostPlaneDiagnostics.ps1 not found at $script:DiagnosticsScript"
    }
  }

  It 'writes a ready host-plane report when native 64-bit and 32-bit LabVIEW 2026 are present' {
    $work = Join-Path $TestDrive 'ready'
    $x64LabVIEW = Join-Path $work 'Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
    $x32LabVIEW = Join-Path $work 'Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
    $sharedCli = Join-Path $work 'Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $lvCompare = Join-Path $work 'Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    $outputPath = Join-Path $work 'labview-2026-host-plane-report.json'
    $summaryPath = Join-Path $work 'labview-2026-host-plane-summary.md'

    foreach ($path in @($x64LabVIEW, $x32LabVIEW, $sharedCli, $lvCompare)) {
      $dir = Split-Path -Parent $path
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      Set-Content -LiteralPath $path -Encoding ascii -Value ''
    }

    $output = & pwsh -NoLogo -NoProfile -File $script:DiagnosticsScript `
      -LabVIEW64Path $x64LabVIEW `
      -LabVIEW32Path $x32LabVIEW `
      -LabVIEWCli64Path $sharedCli `
      -LabVIEWCli32Path $sharedCli `
      -LVComparePath $lvCompare `
      -OutputPath $outputPath `
      -GitHubOutputPath '' *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = $output -join "`n"
    $outputText | Should -Match '\[native-labview-2026-64\]\[host-plane\] status=ready'
    $outputText | Should -Match '\[native-labview-2026-32\]\[host-plane\] status=ready'
    $outputText | Should -Match '\[host-plane-split\]\[runner\] hostIsRunner=True'
    $outputText | Should -Match 'candidateParallelPairs=docker-desktop/windows-container-2026\+native-labview-2026-64,native-labview-2026-64\+native-labview-2026-32'
    $outputText | Should -Match '\[host-plane-split\]\[summary\]'

    $report = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 12
    $report.schema | Should -Be 'labview-2026-host-plane-report@v1'
    $report.runner.hostIsRunner | Should -BeTrue
    $report.runner.runnerName | Should -Not -BeNullOrEmpty
    $report.policy.authoritativePlanes | Should -Contain 'docker-desktop/linux-container-2026'
    $report.policy.authoritativePlanes | Should -Contain 'docker-desktop/windows-container-2026'
    $report.policy.hostNativeShadowPlane.plane | Should -Be 'native-labview-2026-32'
    $report.policy.hostNativeShadowPlane.role | Should -Be 'acceleration-surface'
    $report.policy.hostNativeShadowPlane.authoritative | Should -BeFalse
    $report.policy.hostNativeShadowPlane.executionMode | Should -Be 'manual-opt-in'
    $report.policy.hostNativeShadowPlane.hostedCiAllowed | Should -BeFalse
    $report.policy.hostNativeShadowPlane.promotionPrerequisites | Should -Contain 'docker-desktop/windows-container-2026'
    $report.native.planes.x64.status | Should -Be 'ready'
    $report.native.planes.x32.status | Should -Be 'ready'
    $report.native.parallelLabVIEWSupported | Should -BeTrue
    $report.executionPolicy.provenParallelPairs.pairs.Count | Should -Be 2
    $report.executionPolicy.candidateParallelPairs.pairs.Count | Should -Be 2
    $report.executionPolicy.mutuallyExclusivePairs.pairs.Count | Should -Be 1
    $report.native.planes.x64.cliPath | Should -Be $sharedCli
    $report.native.planes.x32.cliPath | Should -Be $sharedCli

    Test-Path -LiteralPath $summaryPath | Should -BeTrue
    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match '# LabVIEW 2026 Host Plane Summary'
    $summary | Should -Match '- Native 64-bit: `ready`'
    $summary | Should -Match '- Native 32-bit: `ready`'
    $summary | Should -Match 'Host-native 32-bit shadow: `acceleration-surface`'
    $summary | Should -Match 'authoritative=False'
    $summary | Should -Match 'hostedCiAllowed=False'
    $summary | Should -Match 'docker-desktop/windows-container-2026 \+ native-labview-2026-64'
  }

  It 'reports the 32-bit host plane as missing when only native 64-bit is available' {
    $work = Join-Path $TestDrive 'x64-only'
    $x64LabVIEW = Join-Path $work 'Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
    $missing32LabVIEW = Join-Path $work 'Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
    $sharedCli = Join-Path $work 'Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $lvCompare = Join-Path $work 'Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    $outputPath = Join-Path $work 'labview-2026-host-plane-report.json'

    foreach ($path in @($x64LabVIEW, $sharedCli, $lvCompare)) {
      $dir = Split-Path -Parent $path
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      Set-Content -LiteralPath $path -Encoding ascii -Value ''
    }

    $output = & pwsh -NoLogo -NoProfile -File $script:DiagnosticsScript `
      -LabVIEW64Path $x64LabVIEW `
      -LabVIEW32Path $missing32LabVIEW `
      -LabVIEWCli64Path $sharedCli `
      -LabVIEWCli32Path $sharedCli `
      -LVComparePath $lvCompare `
      -OutputPath $outputPath `
      -GitHubOutputPath '' *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $report = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 12
    $report.native.planes.x64.status | Should -Be 'ready'
    $report.native.planes.x32.status | Should -Be 'partial'
    $report.native.planes.x32.issues | Should -Contain 'labview-exe-missing'
    $report.native.parallelLabVIEWSupported | Should -BeFalse
    $report.executionPolicy.candidateParallelPairs.pairs.Count | Should -Be 1
    $report.executionPolicy.candidateParallelPairs.pairs[0].left | Should -Be 'docker-desktop/windows-container-2026'
    $report.executionPolicy.candidateParallelPairs.pairs[0].right | Should -Be 'native-labview-2026-64'
  }

  It 'writes GitHub outputs for host-plane status and report path' {
    $work = Join-Path $TestDrive 'github-output'
    $x64LabVIEW = Join-Path $work 'Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
    $x32LabVIEW = Join-Path $work 'Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
    $sharedCli = Join-Path $work 'Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $lvCompare = Join-Path $work 'Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    $outputPath = Join-Path $work 'labview-2026-host-plane-report.json'
    $githubOutput = Join-Path $work 'github-output.txt'

    foreach ($path in @($x64LabVIEW, $x32LabVIEW, $sharedCli, $lvCompare)) {
      $dir = Split-Path -Parent $path
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      Set-Content -LiteralPath $path -Encoding ascii -Value ''
    }

    $output = & pwsh -NoLogo -NoProfile -File $script:DiagnosticsScript `
      -LabVIEW64Path $x64LabVIEW `
      -LabVIEW32Path $x32LabVIEW `
      -LabVIEWCli64Path $sharedCli `
      -LabVIEWCli32Path $sharedCli `
      -LVComparePath $lvCompare `
      -OutputPath $outputPath `
      -GitHubOutputPath $githubOutput *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = Get-Content -LiteralPath $githubOutput -Raw
    $outputText | Should -Match 'labview-2026-host-plane-report-path='
    $outputText | Should -Match 'labview-2026-host-plane-summary-path='
    $outputText | Should -Match 'labview-2026-native-64-status=ready'
    $outputText | Should -Match 'labview-2026-native-32-status=ready'
    $outputText | Should -Match 'labview-2026-native-parallel-supported=True'
  }
}
