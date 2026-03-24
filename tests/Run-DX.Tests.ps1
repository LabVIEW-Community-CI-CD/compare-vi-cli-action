Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Run-DX.ps1 (TestStand staging)' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunDxPath = Join-Path $repoRoot 'tools' 'Run-DX.ps1'
    $script:StageScriptPath = Join-Path $repoRoot 'tools' 'Stage-CompareInputs.ps1'
    Test-Path -LiteralPath $script:RunDxPath | Should -BeTrue
    Test-Path -LiteralPath $script:StageScriptPath | Should -BeTrue
  }

  It 'stages duplicate filenames by default and cleans up temp directory' {
    $work = Join-Path $TestDrive 'dx-stage-default'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath $script:RunDxPath -Destination 'tools/Run-DX.ps1'
      Copy-Item -LiteralPath $script:StageScriptPath -Destination 'tools/Stage-CompareInputs.ps1'
      $runDxContent = Get-Content -LiteralPath (Join-Path $work 'tools/Run-DX.ps1') -Raw
      $runDxContent = $runDxContent -replace '(?m)^exit \$exit$', 'return $exit'
      Set-Content -LiteralPath (Join-Path $work 'tools/Run-DX.ps1') -Value $runDxContent -Encoding UTF8
$harnessStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputRoot,
  [string]$StagingRoot,
  [string]$AgentId,
  [string]$AgentClass,
  [string]$ExecutionCellLeasePath,
  [string]$ExecutionCellId,
  [string]$ExecutionCellLeaseId,
  [string]$HarnessInstanceId,
  [switch]$SameNameHint,
  [switch]$AllowSameLeaf,
  [string]$NoiseProfile,
  [string]$Warmup
)
if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
$log = [ordered]@{
  base          = $BaseVi
  head          = $HeadVi
  stagingRoot   = $StagingRoot
  agentId       = $AgentId
  agentClass    = $AgentClass
  executionCellLeasePath = $ExecutionCellLeasePath
  executionCellId = $ExecutionCellId
  executionCellLeaseId = $ExecutionCellLeaseId
  harnessInstanceId = $HarnessInstanceId
  sameNameHint  = $SameNameHint.IsPresent
  allowSameLeaf = $AllowSameLeaf.IsPresent
  noiseProfile  = $NoiseProfile
  warmup        = $Warmup
}
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'harness-log.json') -Encoding utf8
$session = [ordered]@{
  schema = 'teststand-compare-session/v1'
  suiteClass = 'single-compare'
  requestedSimultaneous = $false
  warmup = @{
    mode   = $Warmup
    events = $null
  }
  compare = @{
    events  = $null
    capture = $null
    report  = $false
    staging = @{
      enabled = (-not [string]::IsNullOrWhiteSpace($StagingRoot))
      root    = $StagingRoot
    }
    allowSameLeaf = $AllowSameLeaf.IsPresent
    mode    = 'labview-cli'
    autoCli = $SameNameHint.IsPresent
  }
  outcome = $null
  error   = $null
  executionCell = @{
    cellId = $ExecutionCellId
    leaseId = $ExecutionCellLeaseId
    leasePath = $ExecutionCellLeasePath
    agentId = $AgentId
    agentClass = $AgentClass
    cellClass = 'worker'
    suiteClass = 'single-compare'
    operatorAuthorizationRef = 'budget-auth://operator/session-2026-03-24'
    premiumSaganMode = $false
  }
  harnessInstance = @{
    harnessKind = 'teststand-compare-harness'
    instanceId = $HarnessInstanceId
    leaseId = 'harness-lease-hooke-01'
    leasePath = 'tests/results/teststand/harness-hooke-01.json'
    role = 'single-plane'
    processModelClass = 'sequential-process-model'
  }
  processModel = @{
    runtimeSurface = 'windows-native-teststand'
    processModelClass = 'sequential-process-model'
    windowsOnly = $true
    rootHarnessInstanceId = $HarnessInstanceId
    planeCount = 1
  }
}
$session | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'session-index.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath (Join-Path $work 'tools/TestStand-CompareHarness.ps1') -Value $harnessStub -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $work 'tools/Debug-ChildProcesses.ps1') -Encoding UTF8 -Value "param() exit 0"
      Set-Content -LiteralPath (Join-Path $work 'tools/Detect-RogueLV.ps1') -Encoding UTF8 -Value "param() exit 0"

      $baseDir = Join-Path $work 'base'
      $headDir = Join-Path $work 'head'
      New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
      $baseVi = Join-Path $baseDir 'Sample.vi'
      $headVi = Join-Path $headDir 'Sample.vi'
      Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
      Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

      $outputRoot = Join-Path $work 'results'
      $runDx = Join-Path $work 'tools/Run-DX.ps1'
      $result = & $runDx `
        -Suite TestStand `
        -BaseVi $baseVi `
        -HeadVi $headVi `
        -OutputRoot $outputRoot `
        -ResultsPath $outputRoot `
        -Warmup skip `
        -AgentId hooke `
        -AgentClass subagent `
        -ExecutionCellLeasePath 'E:\comparevi-lanes\cells\hooke-01\execution-cell.json' `
        -ExecutionCellId 'exec-cell-hooke-01' `
        -ExecutionCellLeaseId 'lease-hooke-01' `
        -HarnessInstanceId 'harness-hooke-01'
      $result | Should -Be 0

      $logPath = Join-Path $outputRoot 'harness-log.json'
      Test-Path -LiteralPath $logPath | Should -BeTrue
      $log = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $allowedLegacy = @((Split-Path -Leaf $baseVi), (Split-Path -Leaf $headVi), 'Base.vi', 'Head.vi') | Select-Object -Unique
      $legacyPattern = '({0})$' -f (($allowedLegacy | ForEach-Object { [regex]::Escape($_) }) -join '|')
      $log.base | Should -Match $legacyPattern
      $log.head | Should -Match $legacyPattern
      $log.sameNameHint | Should -BeTrue
      $log.allowSameLeaf | Should -BeFalse
      $log.stagingRoot | Should -Not -BeNullOrEmpty
      $log.agentId | Should -Be 'hooke'
      $log.agentClass | Should -Be 'subagent'
      $log.executionCellId | Should -Be 'exec-cell-hooke-01'
      $log.executionCellLeaseId | Should -Be 'lease-hooke-01'
      $log.harnessInstanceId | Should -Be 'harness-hooke-01'
      $log.noiseProfile | Should -Be 'full'
      Test-Path -LiteralPath $log.stagingRoot | Should -BeFalse

      $sessionPath = Join-Path $outputRoot 'session-index.json'
      $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      $session.compare.staging.enabled | Should -BeTrue
      $session.compare.staging.root | Should -Be $log.stagingRoot
      $session.compare.allowSameLeaf | Should -BeFalse
      $session.executionCell.cellId | Should -Be 'exec-cell-hooke-01'
      $session.executionCell.leaseId | Should -Be 'lease-hooke-01'
      $session.harnessInstance.instanceId | Should -Be 'harness-hooke-01'
      $session.processModel.runtimeSurface | Should -Be 'windows-native-teststand'
      $session.processModel.processModelClass | Should -Be 'sequential-process-model'
      $statusPath = Join-Path $outputRoot '_agent/dx-status.json'
      $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
      $status.executionTopology.suiteClass | Should -Be 'single-compare'
      $status.executionTopology.runtimeSurface | Should -Be 'windows-native-teststand'
      $status.executionTopology.processModelClass | Should -Be 'sequential-process-model'
      $status.executionTopology.requestedSimultaneous | Should -BeFalse
      $status.executionTopology.cellClass | Should -Be 'worker'
      $status.executionTopology.operatorAuthorizationRef | Should -Be 'budget-auth://operator/session-2026-03-24'
      $status.executionTopology.premiumSaganMode | Should -BeFalse
      $status.executionTopology.harnessKind | Should -Be 'teststand-compare-harness'
      $status.executionTopology.harnessInstanceId | Should -Be 'harness-hooke-01'
      $status.executionTopology.harnessInstanceLeaseId | Should -Be 'harness-lease-hooke-01'
      $status.executionTopology.harnessInstanceLeasePath | Should -Be 'tests/results/teststand/harness-hooke-01.json'
      $status.executionTopology.executionCellId | Should -Be 'exec-cell-hooke-01'
      $status.executionTopology.executionCellLeaseId | Should -Be 'lease-hooke-01'
    }
    finally { Pop-Location }
  }

  It 'respects -UseRawPaths and skips staging' {
    $work = Join-Path $TestDrive 'dx-raw-paths'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath $script:RunDxPath -Destination 'tools/Run-DX.ps1'
      Copy-Item -LiteralPath $script:StageScriptPath -Destination 'tools/Stage-CompareInputs.ps1'
      $runDxContent = Get-Content -LiteralPath (Join-Path $work 'tools/Run-DX.ps1') -Raw
      $runDxContent = $runDxContent -replace '(?m)^exit \$exit$', 'return $exit'
      Set-Content -LiteralPath (Join-Path $work 'tools/Run-DX.ps1') -Value $runDxContent -Encoding UTF8
$harnessStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputRoot,
  [string]$StagingRoot,
  [string]$AgentId,
  [string]$AgentClass,
  [string]$ExecutionCellLeasePath,
  [string]$ExecutionCellId,
  [string]$ExecutionCellLeaseId,
  [string]$HarnessInstanceId,
  [switch]$SameNameHint,
  [switch]$AllowSameLeaf,
  [string]$NoiseProfile,
  [string]$Warmup
)
if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
$log = [ordered]@{
  base          = $BaseVi
  head          = $HeadVi
  stagingRoot   = $StagingRoot
  agentId       = $AgentId
  agentClass    = $AgentClass
  executionCellLeasePath = $ExecutionCellLeasePath
  executionCellId = $ExecutionCellId
  executionCellLeaseId = $ExecutionCellLeaseId
  harnessInstanceId = $HarnessInstanceId
  sameNameHint  = $SameNameHint.IsPresent
  allowSameLeaf = $AllowSameLeaf.IsPresent
  noiseProfile  = $NoiseProfile
  warmup        = $Warmup
}
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'harness-log.json') -Encoding utf8
$session = [ordered]@{
  schema = 'teststand-compare-session/v1'
  suiteClass = 'single-compare'
  requestedSimultaneous = $false
  warmup = @{
    mode   = $Warmup
    events = $null
  }
  compare = @{
    events  = $null
    capture = $null
    report  = $false
    staging = @{
      enabled = (-not [string]::IsNullOrWhiteSpace($StagingRoot))
      root    = $StagingRoot
    }
    allowSameLeaf = $AllowSameLeaf.IsPresent
    mode    = 'labview-cli'
    autoCli = $SameNameHint.IsPresent
  }
  outcome = $null
  error   = $null
  executionCell = @{
    cellId = $ExecutionCellId
    leaseId = $ExecutionCellLeaseId
    leasePath = $ExecutionCellLeasePath
    agentId = $AgentId
    agentClass = $AgentClass
    cellClass = 'worker'
    suiteClass = 'single-compare'
    operatorAuthorizationRef = $null
    premiumSaganMode = $false
  }
  harnessInstance = @{
    harnessKind = 'teststand-compare-harness'
    instanceId = $HarnessInstanceId
    role = 'single-plane'
    processModelClass = 'sequential-process-model'
  }
  processModel = @{
    runtimeSurface = 'windows-native-teststand'
    processModelClass = 'sequential-process-model'
    windowsOnly = $true
    rootHarnessInstanceId = $HarnessInstanceId
    planeCount = 1
  }
}
$session | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'session-index.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath (Join-Path $work 'tools/TestStand-CompareHarness.ps1') -Value $harnessStub -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $work 'tools/Debug-ChildProcesses.ps1') -Encoding UTF8 -Value "param() exit 0"
      Set-Content -LiteralPath (Join-Path $work 'tools/Detect-RogueLV.ps1') -Encoding UTF8 -Value "param() exit 0"

      $baseLeaf = ('Bas' + 'e') + '.vi'
      $baseVi = Join-Path $work $baseLeaf
      $headVi = Join-Path $work 'HeadDifferent.vi'
      Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
      Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

      $outputRoot = Join-Path $work 'results'
      $runDx = Join-Path $work 'tools/Run-DX.ps1'
      $result = & $runDx `
        -Suite TestStand `
        -BaseVi $baseVi `
        -HeadVi $headVi `
        -OutputRoot $outputRoot `
        -ResultsPath $outputRoot `
        -Warmup detect `
        -UseRawPaths `
        -NoiseProfile legacy
      $result | Should -Be 0

      $logPath = Join-Path $outputRoot 'harness-log.json'
      Test-Path -LiteralPath $logPath | Should -BeTrue
      $log = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $log.base | Should -Be (Resolve-Path $baseVi).Path
      $log.head | Should -Be (Resolve-Path $headVi).Path
      $log.stagingRoot | Should -BeNullOrEmpty
      $log.sameNameHint | Should -BeFalse
      $log.allowSameLeaf | Should -BeFalse
      $log.noiseProfile | Should -Be 'legacy'

      $sessionPath = Join-Path $outputRoot 'session-index.json'
      $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      $session.compare.staging.enabled | Should -BeFalse
      $session.compare.autoCli | Should -BeFalse
      $session.compare.allowSameLeaf | Should -BeFalse
    }
    finally { Pop-Location }
  }

  It 'declares dual-plane parity forwarding and status projection in the wrapper contract' {
    $content = Get-Content -LiteralPath $script:RunDxPath -Raw

    $content | Should -Match '\[string\]\$LabVIEW64ExePath'
    $content | Should -Match '\[string\]\$LabVIEW32ExePath'
    $content | Should -Match '\[string\]\$AgentId'
    $content | Should -Match '\[string\]\$AgentClass'
    $content | Should -Match '\[string\]\$ExecutionCellLeasePath'
    $content | Should -Match '\[string\]\$ExecutionCellId'
    $content | Should -Match '\[string\]\$ExecutionCellLeaseId'
    $content | Should -Match '\[string\]\$HarnessInstanceId'
    $content | Should -Match "\[ValidateSet\('single-compare','dual-plane-parity'\)\]\s*\[string\]\`$TestStandSuiteClass"
    $content | Should -Match '\$hParams\.LabVIEW64ExePath\s*=\s*\$LabVIEW64ExePath'
    $content | Should -Match '\$hParams\.LabVIEW32ExePath\s*=\s*\$LabVIEW32ExePath'
    $content | Should -Match '\$hParams\.SuiteClass\s*=\s*\$TestStandSuiteClass'
    $content | Should -Match '\$hParams\.AgentId\s*=\s*\$AgentId'
    $content | Should -Match '\$hParams\.AgentClass\s*=\s*\$AgentClass'
    $content | Should -Match '\$hParams\.ExecutionCellLeasePath\s*=\s*\$ExecutionCellLeasePath'
    $content | Should -Match '\$hParams\.ExecutionCellId\s*=\s*\$ExecutionCellId'
    $content | Should -Match '\$hParams\.ExecutionCellLeaseId\s*=\s*\$ExecutionCellLeaseId'
    $content | Should -Match '\$hParams\.HarnessInstanceId\s*=\s*\$HarnessInstanceId'
    $content | Should -Match 'suiteClass\s*=\s*if\s*\(\$session\.PSObject\.Properties\.Name\s*-contains\s*''suiteClass''\)'
    $content | Should -Match 'primaryPlane\s*=\s*Get-SessionValue\s+\$session\s+''primaryPlane'''
    $content | Should -Match 'Get-SessionBoolValue'
    $content | Should -Match '\$requestedSimultaneous\s*=\s*\$false'
    $content | Should -Match 'requestedSimultaneous\s*=\s*\$requestedSimultaneous'
    $content | Should -Match 'executionTopology\s*=\s*@\{'
    $content | Should -Match 'executionCell\s*=\s*Get-SessionValue\s+\$session\s+''executionCell'''
    $content | Should -Match 'harnessInstance\s*=\s*Get-SessionValue\s+\$session\s+''harnessInstance'''
    $content | Should -Match 'harnessInstanceLeaseId\s*='
    $content | Should -Match 'harnessInstanceLeasePath\s*='
    $content | Should -Match 'processModel\s*=\s*Get-SessionValue\s+\$session\s+''processModel'''
    $content | Should -Match 'parity\s*=\s*Get-SessionValue\s+\$session\s+''parity'''
    $content | Should -Match 'planes\s*=\s*Get-SessionValue\s+\$session\s+''planes'''
  }
}
