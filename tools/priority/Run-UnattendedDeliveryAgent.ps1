#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Repo = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$RuntimeDir = 'tests/results/_agent/runtime',
  [int]$DaemonPollIntervalSeconds = 60,
  [int]$CycleIntervalSeconds = 90,
  [int]$MaxCycles = 0,
  [switch]$QueueApply,
  [switch]$NoPortfolioApply,
  [switch]$StopWhenNoOpenIssues,
  [string]$ProjectStatus = 'In Progress',
  [string]$ProjectProgram = 'Shared Infra',
  [string]$ProjectPhase = 'Helper Workflow',
  [string]$ProjectEnvironmentClass = 'Infra',
  [string]$ProjectBlockingSignal = 'Scope',
  [string]$ProjectEvidenceState = 'Partial',
  [string]$ProjectPortfolioTrack = 'Agent UX',
  [switch]$SleepMode,
  [int]$QueuePauseRecoveryThresholdCycles = 2,
  [int]$QueuePauseRecoveryCooldownMinutes = 30,
  [int]$QueuePauseRecoveryMaxAttempts = 8,
  [string]$QueuePauseRecoveryRef = 'develop',
  [switch]$DispatchValidateOnQueuePause,
  [switch]$QueuePauseRecoveryAllowFork,
  [switch]$OnlyRecoverQueueWhenEligible,
  [int]$MaxConsecutiveCycleFailures = 3,
  [switch]$AutoBootstrapOnFailure,
  [switch]$AutoPrioritySyncLane,
  [switch]$AutoDevelopSync,
  [int]$CodexHygieneIntervalCycles = 3,
  [string]$WslDistro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeliveryAgentWrapper.Build.psm1') -Force
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$distScript = Join-Path $repoRoot 'dist\tools\priority\delivery-agent.js'
Initialize-DeliveryAgentDistScript -RepoRoot $repoRoot -DistScript $distScript -WrapperLabel 'delivery-agent runner wrapper'

$args = @(
  $distScript,
  'run',
  '--repo', $Repo,
  '--runtime-dir', $RuntimeDir,
  '--daemon-poll-interval-seconds', "$DaemonPollIntervalSeconds",
  '--cycle-interval-seconds', "$CycleIntervalSeconds",
  '--max-cycles', "$MaxCycles",
  '--project-status', $ProjectStatus,
  '--project-program', $ProjectProgram,
  '--project-phase', $ProjectPhase,
  '--project-environment-class', $ProjectEnvironmentClass,
  '--project-blocking-signal', $ProjectBlockingSignal,
  '--project-evidence-state', $ProjectEvidenceState,
  '--project-portfolio-track', $ProjectPortfolioTrack,
  '--queue-pause-recovery-threshold-cycles', "$QueuePauseRecoveryThresholdCycles",
  '--queue-pause-recovery-cooldown-minutes', "$QueuePauseRecoveryCooldownMinutes",
  '--queue-pause-recovery-max-attempts', "$QueuePauseRecoveryMaxAttempts",
  '--queue-pause-recovery-ref', $QueuePauseRecoveryRef,
  '--max-consecutive-cycle-failures', "$MaxConsecutiveCycleFailures",
  '--codex-hygiene-interval-cycles', "$CodexHygieneIntervalCycles",
  '--wsl-distro', $WslDistro
)
foreach ($flag in @(
  @{ Enabled = $QueueApply; Name = '--queue-apply' },
  @{ Enabled = $NoPortfolioApply; Name = '--no-portfolio-apply' },
  @{ Enabled = $StopWhenNoOpenIssues; Name = '--stop-when-no-open-issues' },
  @{ Enabled = $SleepMode; Name = '--sleep-mode' },
  @{ Enabled = $DispatchValidateOnQueuePause; Name = '--dispatch-validate-on-queue-pause' },
  @{ Enabled = $QueuePauseRecoveryAllowFork; Name = '--queue-pause-recovery-allow-fork' },
  @{ Enabled = $OnlyRecoverQueueWhenEligible; Name = '--only-recover-queue-when-eligible' },
  @{ Enabled = $AutoBootstrapOnFailure; Name = '--auto-bootstrap-on-failure' },
  @{ Enabled = $AutoPrioritySyncLane; Name = '--auto-priority-sync-lane' },
  @{ Enabled = $AutoDevelopSync; Name = '--auto-develop-sync' }
)) {
  if ($flag.Enabled) {
    $args += $flag.Name
  }
}

& node @args
exit $LASTEXITCODE
