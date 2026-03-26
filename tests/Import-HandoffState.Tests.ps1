Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Import-HandoffState' -Tag 'Unit' {
  It 'surfaces the handoff entrypoint index when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $fixturePath = Join-Path $repoRoot 'tools' 'priority' '__fixtures__' 'handoff' 'entrypoint-status.json'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $handoffDir 'entrypoint-status.json') -Force

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Entrypoint index'
    $output | Should -Match 'status\s+: pass'
    $output | Should -Match 'command\.bootstrap'
    $output | Should -Match 'artifact\.entrypointStatus'
    (Get-Variable -Name HandoffEntrypointStatus -Scope Global -ValueOnly).schema | Should -Be 'agent-handoff/entrypoint-status-v1'

    Remove-Variable -Name HandoffEntrypointStatus -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces the Docker review-loop summary when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $fixturePath = Join-Path $repoRoot 'tools' 'priority' '__fixtures__' 'handoff' 'docker-review-loop-summary.json'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $handoffDir 'docker-review-loop-summary.json') -Force

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Docker review loop summary'
    $output | Should -Match 'status\s+: passed'
    $output | Should -Match 'head\s+: 433e8aa70326007be74c27ccf54c1ae91559b6f3'
    (Get-Variable -Name DockerReviewLoopHandoffSummary -Scope Global -ValueOnly).schema | Should -Be 'docker-tools-parity-agent-verification@v1'

    Remove-Variable -Name DockerReviewLoopHandoffSummary -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces plane transition evidence when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'agent-handoff/plane-transition-v1'
      generatedAt = '2026-03-14T08:40:00Z'
      status = 'ok'
      reason = $null
      transitionCount = 1
      transitions = @(
        [ordered]@{
          from = 'upstream'
          to = 'origin'
          action = 'sync'
          via = 'priority:develop:sync'
          sourceType = 'develop-sync'
          sourceLabel = 'develop-sync-report'
        }
      )
      sources = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'plane-transition.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Plane transition evidence'
    $output | Should -Match 'status\s+: ok'
    $output | Should -Match 'upstream->origin'
    (Get-Variable -Name PlaneTransitionHandoffSummary -Scope Global -ValueOnly).schema | Should -Be 'agent-handoff/plane-transition-v1'

    Remove-Variable -Name PlaneTransitionHandoffSummary -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces turn-boundary continuity supervision when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'priority/continuity-telemetry-report@v1'
      generatedAt = '2026-03-21T20:00:00Z'
      repoRoot = 'C:\repo'
      status = 'maintained'
      issueContext = [ordered]@{
        mode = 'issue'
        issue = 1711
        present = $true
        fresh = $true
        observedAt = '2026-03-21T19:58:00Z'
        reason = $null
      }
      continuity = [ordered]@{
        status = 'maintained'
        preservedWithoutPrompt = $true
        promptDependency = 'low'
        unattendedSignalCount = 4
        quietPeriod = [ordered]@{
          status = 'covered'
          continuityReferenceAt = '2026-03-21T19:59:00Z'
          silenceGapSeconds = 60
          operatorQuietPeriodTreatedAsPause = $false
        }
        turnBoundary = [ordered]@{
          status = 'active-work-pending'
          supervisionState = 'supervised-background'
          operatorTurnEndWouldCreateIdleGap = $false
          operatorPromptRequiredToResume = $false
          activeLaneIssue = 1711
          wakeCondition = 'github-checks-finished'
          source = 'delivery-state'
          reason = 'standing issue #1711 is supervised in the background'
          pendingActions = @('Resume when wake condition ''github-checks-finished'' is satisfied for standing issue #1711.')
        }
        recommendation = 'Resume when wake condition ''github-checks-finished'' is satisfied for standing issue #1711.'
      }
      sources = [ordered]@{
        writerLease = [ordered]@{ path = 'writer.json'; exists = $true; observedAt = '2026-03-21T19:59:00Z'; ageSeconds = 60; freshnessThresholdSeconds = 1800; fresh = $true; error = $null }
        router = [ordered]@{ path = 'router.json'; exists = $true; observedAt = '2026-03-21T19:58:00Z'; ageSeconds = 120; freshnessThresholdSeconds = 21600; fresh = $true; error = $null }
        noStanding = [ordered]@{ path = 'no-standing.json'; exists = $false; observedAt = $null; ageSeconds = $null; freshnessThresholdSeconds = 21600; fresh = $false; error = $null }
        handoffEntrypoint = [ordered]@{ path = 'entrypoint-status.json'; exists = $true; observedAt = '2026-03-21T19:57:00Z'; ageSeconds = 180; freshnessThresholdSeconds = 86400; fresh = $true; error = $null }
        sessions = [ordered]@{ path = 'sessions'; exists = $true; observedAt = '2026-03-21T19:56:00Z'; ageSeconds = 240; freshnessThresholdSeconds = 604800; fresh = $true; count = 1; latestPath = 'session.json' }
        deliveryState = [ordered]@{ path = 'delivery-agent-state.json'; exists = $true; observedAt = '2026-03-21T19:55:00Z'; ageSeconds = 300; freshnessThresholdSeconds = 21600; fresh = $true; error = $null }
        observerHeartbeat = [ordered]@{ path = 'observer-heartbeat.json'; exists = $false; observedAt = $null; ageSeconds = $null; freshnessThresholdSeconds = 21600; fresh = $false; error = $null }
      }
      artifacts = [ordered]@{
        runtimePath = 'tests/results/_agent/runtime/continuity-telemetry.json'
        handoffPath = 'tests/results/_agent/handoff/continuity-summary.json'
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'continuity-summary.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Continuity summary'
    $output | Should -Match 'supervision\s+: supervised-background'
    $output | Should -Match 'prompt-resume\s+: false'
    $output | Should -Match 'pending\s+: Resume when wake condition'
    (Get-Variable -Name HandoffContinuitySummary -Scope Global -ValueOnly).schema | Should -Be 'priority/continuity-telemetry-report@v1'

    Remove-Variable -Name HandoffContinuitySummary -Scope Global -ErrorAction SilentlyContinue
  }
  It 'surfaces monitoring-mode state when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'agent-handoff/monitoring-mode-v1'
      generatedAt = '2026-03-22T13:00:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      policy = [ordered]@{
        path = 'tools/policy/template-monitoring.json'
        compareRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        pivotTargetRepository = 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
        wakeConditions = @('compare-queue-not-empty')
      }
      compare = [ordered]@{
        queueState = [ordered]@{ reportPath = 'tests/results/_agent/issue/no-standing-priority.json'; ready = $true; status = 'queue-empty'; detail = 'queue-empty' }
        continuity = [ordered]@{ reportPath = 'tests/results/_agent/handoff/continuity-summary.json'; ready = $true; status = 'maintained'; detail = 'safe-idle' }
        pivotGate = [ordered]@{ reportPath = 'tests/results/_agent/promotion/template-pivot-gate-report.json'; ready = $true; status = 'ready'; detail = 'future-agent-may-pivot' }
        readyForMonitoring = $true
      }
      templateMonitoring = [ordered]@{
        status = 'pass'
        repositories = @()
        unsupportedPaths = @()
      }
      wakeConditions = @()
      summary = [ordered]@{
        status = 'active'
        futureAgentAction = 'future-agent-may-pivot'
        wakeConditionCount = 0
        triggeredWakeConditions = @()
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'monitoring-mode.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Monitoring mode'
    $output | Should -Match 'action\s+: future-agent-may-pivot'
    $output | Should -Match 'template\s+: pass'
    (Get-Variable -Name HandoffMonitoringMode -Scope Global -ValueOnly).schema | Should -Be 'agent-handoff/monitoring-mode-v1'

    Remove-Variable -Name HandoffMonitoringMode -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces treasury ledger state when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'priority/treasury-ledger@v1'
      generatedAt = '2026-03-26T06:25:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      inputs = [ordered]@{
        invoiceMetadataPath = 'C:\Users\sveld\Downloads\Invoice-HQ1VJLMV-0030.json'
        normalizedInvoiceTurnPath = 'tests/results/_agent/cost/invoice-turns/HQ1VJLMV-0030.local.json'
        usageExportCsvPath = 'C:\Users\sveld\Downloads\usage.csv'
        normalizedUsageExportPath = 'tests/results/_agent/cost/usage-exports/mar-usage.json'
        costRollupPath = 'tests/results/_agent/cost/agent-cost-rollup.json'
        operatorSteeringEventPath = 'tests/results/_agent/runtime/operator-steering-event.json'
      }
      events = [ordered]@{
        hardStop = [ordered]@{
          status = 'observed'
          observedAt = '2026-03-25T23:50:00Z'
          sourceKind = 'invoice-metadata'
          reason = 'credit exhaustion observed'
        }
        replenishment = [ordered]@{
          status = 'observed'
          observedAt = '2026-03-26T00:10:00Z'
          sourceKind = 'operator-invoice'
          reason = 'new invoice opened'
          invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0030'
          invoiceId = 'HQ1VJLMV-0030'
          openedAt = '2026-03-26T00:10:00Z'
          creditsPurchased = 5000
          prepaidUsd = 200
          activationState = 'active'
          fundingPurpose = 'operational'
          sourcePathEvidence = 'C:\Users\sveld\Downloads\Invoice-HQ1VJLMV-0030.pdf'
        }
        resume = [ordered]@{
          status = 'observed'
          observedAt = '2026-03-26T00:12:00Z'
          sourceKind = 'invoice-metadata'
          reason = 'resume observed'
        }
      }
      fundingWindow = [ordered]@{
        status = 'selected'
        source = 'normalized-invoice-turn'
        invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0030'
        invoiceId = 'HQ1VJLMV-0030'
        openedAt = '2026-03-26T00:10:00Z'
        activationState = 'active'
        fundingPurpose = 'operational'
      }
      observedBurn = [ordered]@{
        status = 'fail-closed'
        normalizedUsageExportPath = 'tests/results/_agent/cost/usage-exports/mar-usage.json'
        sourcePathEvidence = 'C:\Users\sveld\Downloads\LabVIEW Open-Source Initiative Credit Usage Report (Mar 15 - Apr 15) (3).csv'
        startDate = '2026-03-15'
        endDate = '2026-03-24'
        usageCredits = 24685.09
        usageQuantity = 493701.8
        filenameRangeStatus = 'mismatch'
        declaredFileRange = [ordered]@{
          startLabel = 'Mar 15'
          endLabel = 'Apr 15'
          startMonth = 3
          startDay = 15
          endMonth = 4
          endDay = 15
        }
        reason = 'filename range is broader than observed rows'
      }
      remainingCapitalPosture = [ordered]@{
        status = 'fail-closed'
        source = 'agent-cost-rollup'
        remainingCredits = $null
        remainingUsd = $null
        rollupInvoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0027'
        reason = 'funding-window-rollup-mismatch'
      }
      schedulerState = [ordered]@{
        status = 'fail-closed'
        failClosed = $true
        capitalModeRecommended = 'conserve'
        treasuryPosture = 'replenished-but-unreconciled'
        blockingReasonCodes = @('usage-export-window-mismatch', 'funding-window-rollup-mismatch')
        currentFundingWindowId = 'invoice-turn-2026-03-HQ1VJLMV-0030'
        latestHardStopStatus = 'observed'
        latestResumeStatus = 'observed'
        latestReplenishmentInvoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0030'
      }
      summary = [ordered]@{
        status = 'fail-closed'
        blockerCount = 2
        blockers = @()
        warningCount = 0
        warnings = @()
        currentFundingWindowId = 'invoice-turn-2026-03-HQ1VJLMV-0030'
        latestReplenishmentInvoiceId = 'HQ1VJLMV-0030'
        latestHardStopStatus = 'observed'
        latestResumeStatus = 'observed'
        remainingCapitalStatus = 'fail-closed'
        treasuryPosture = 'replenished-but-unreconciled'
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'treasury-ledger.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Treasury ledger'
    $output | Should -Match 'status\s+: fail-closed'
    $output | Should -Match 'funding\s+: invoice-turn-2026-03-HQ1VJLMV-0030'
    $output | Should -Match 'posture\s+: replenished-but-unreconciled'
    $output | Should -Match 'mode\s+: conserve'
    (Get-Variable -Name HandoffTreasuryLedger -Scope Global -ValueOnly).schema | Should -Be 'priority/treasury-ledger@v1'

    Remove-Variable -Name HandoffTreasuryLedger -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces autonomous governor summary when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'priority/autonomous-governor-summary-report@v1'
      generatedAt = '2026-03-22T22:59:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      inputs = [ordered]@{
        queueEmptyReportPath = 'tests/results/_agent/issue/no-standing-priority.json'
        continuitySummaryPath = 'tests/results/_agent/handoff/continuity-summary.json'
        monitoringModePath = 'tests/results/_agent/handoff/monitoring-mode.json'
        wakeLifecyclePath = 'tests/results/_agent/issue/wake-lifecycle.json'
        wakeInvestmentAccountingPath = 'tests/results/_agent/capital/wake-investment-accounting.json'
        deliveryRuntimeStatePath = 'tests/results/_agent/runtime/delivery-agent-state.json'
        releaseSigningReadinessPath = 'tests/results/_agent/release/release-signing-readiness.json'
      }
      compare = [ordered]@{
        queueState = [ordered]@{ status = 'queue-empty'; reason = 'queue-empty'; openIssueCount = 11; ready = $true }
        continuity = [ordered]@{ status = 'maintained'; turnBoundary = 'safe-idle'; supervisionState = 'safe-idle'; operatorPromptRequiredToResume = $false }
        monitoringMode = [ordered]@{ status = 'active'; futureAgentAction = 'future-agent-may-pivot'; wakeConditionCount = 0 }
        releaseSigningReadiness = [ordered]@{
          status = 'warn'
          codePathState = 'ready'
          signingCapabilityState = 'missing'
          publicationState = 'tag-created-not-pushed'
          publishedBundleState = 'producer-native-incomplete'
          publishedBundleReleaseTag = 'v0.6.3-tools.14'
          publishedBundleAuthoritativeConsumerPin = $null
          externalBlocker = 'workflow-signing-secret-missing'
          blockerCount = 1
        }
        deliveryRuntime = [ordered]@{
          status = 'none'
          runtimeStatus = $null
          laneLifecycle = $null
          actionType = $null
          outcome = $null
          blockerClass = $null
          nextWakeCondition = $null
          queueAuthorityRefresh = [ordered]@{
            attempted = $false
            status = $null
            reason = $null
            summaryPath = $null
            mergeSummaryPath = $null
            receiptGeneratedAt = $null
            receiptStatus = $null
            receiptReason = $null
            evidenceFreshness = $null
            nextWakeCondition = $null
            mergeStateStatus = $null
            isInMergeQueue = $null
            autoMergeEnabled = $null
            mergedAt = $null
          }
          prUrl = $null
          issueNumber = $null
          reason = $null
        }
        queueAuthority = [ordered]@{
          status = 'none'
          source = 'none'
          nextWakeCondition = $null
          summaryPath = $null
          promotionStatus = $null
          mergeStateStatus = $null
          isInMergeQueue = $false
          autoMergeEnabled = $false
          prUrl = $null
        }
      }
      wake = [ordered]@{
        terminalState = 'compare-work'
        currentStage = 'monitoring-work-injection'
        classification = 'branch-target-drift'
        decision = 'compare-governance-work'
        monitoringStatus = 'would-create-issue'
        authoritativeTier = 'authoritative'
        blockedLowerTierEvidence = $true
        replayMatched = $false
        replayAuthorityCompatible = $false
        issueNumber = $null
        issueUrl = $null
        recommendedOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      }
      funding = [ordered]@{
        accountingBucket = 'compare-governance-work'
        status = 'warn'
        paybackStatus = 'neutral'
        recommendation = 'continue-estimated-telemetry'
        invoiceTurnId = 'invoice-turn-2026-03-HQ1VJLMV-0027'
        fundingPurpose = 'operational'
        activationState = 'active'
        benchmarkIssueUsd = 0.0201
        observedWakeIssueUsd = 0.0201
        netPaybackUsd = 0
      }
      summary = [ordered]@{
        governorMode = 'compare-governance-work'
        currentOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextAction = 'continue-compare-governance-work'
        signalQuality = 'validated-governance-work'
        queueState = 'queue-empty'
        continuityStatus = 'maintained'
        wakeTerminalState = 'compare-work'
        monitoringStatus = 'active'
        futureAgentAction = 'future-agent-may-pivot'
        releaseSigningStatus = 'warn'
        releaseSigningExternalBlocker = 'workflow-signing-secret-missing'
        releasePublicationState = 'tag-created-not-pushed'
        releasePublishedBundleState = 'producer-native-incomplete'
        releasePublishedBundleReleaseTag = 'v0.6.3-tools.14'
        releasePublishedBundleAuthoritativeConsumerPin = $null
        queueHandoffStatus = 'none'
        queueHandoffNextWakeCondition = $null
        queueHandoffPrUrl = $null
        queueAuthoritySource = 'none'
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'autonomous-governor-summary.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Autonomous governor summary'
    $output | Should -Match 'mode\s+: compare-governance-work'
    $output | Should -Match 'next\s+: continue-compare-governance-work'
    $output | Should -Match 'release\s+: warn'
    $output | Should -Match 'blocker\s+: workflow-signing-secret-missing'
    $output | Should -Match 'bundle\s+: producer-native-incomplete'
    $output | Should -Match 'bundleTag: v0.6.3-tools.14'
    (Get-Variable -Name HandoffAutonomousGovernorSummary -Scope Global -ValueOnly).schema | Should -Be 'priority/autonomous-governor-summary-report@v1'

    Remove-Variable -Name HandoffAutonomousGovernorSummary -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces governor portfolio summary when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'priority/autonomous-governor-portfolio-summary-report@v1'
      generatedAt = '2026-03-22T23:15:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      inputs = [ordered]@{
        compareGovernorSummaryPath = 'tests/results/_agent/handoff/autonomous-governor-summary.json'
        monitoringModePath = 'tests/results/_agent/handoff/monitoring-mode.json'
        repoGraphTruthPath = 'tests/results/_agent/handoff/downstream-repo-graph-truth.json'
      }
      compare = [ordered]@{
        repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        queueState = 'not-queue-empty'
        continuityStatus = 'at-risk'
        monitoringStatus = 'blocked'
        futureAgentAction = 'stay-in-compare-monitoring'
        governorMode = 'compare-governance-work'
        nextAction = 'continue-compare-governance-work'
        queueHandoffStatus = $null
        queueHandoffNextWakeCondition = $null
        queueHandoffPrUrl = $null
        queueAuthoritySource = $null
      }
      portfolio = [ordered]@{
        repositoryCount = 4
        repositories = @()
        dependencies = @(
          [ordered]@{
            id = 'vi-history-producer-native-distributor'
            status = 'blocked'
            ownerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
            dependentRepository = 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
            requiredCapability = 'vi-history'
            source = 'compare-release-signing-readiness'
            releaseSigningStatus = 'warn'
            releasePublicationState = 'unobserved'
            publishedBundleState = 'producer-native-incomplete'
            publishedBundleReleaseTag = 'v0.6.3-tools.14'
            publishedBundleAuthoritativeConsumerPin = $null
            signingCapabilityState = 'missing'
            externalBlocker = 'workflow-signing-secret-missing'
            detail = 'awaiting-compare-release-signing-blocker-clear'
          }
        )
        unsupportedPaths = @()
      }
      summary = [ordered]@{
        status = 'active'
        governorMode = 'compare-governance-work'
        currentOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextAction = 'continue-compare-governance-work'
        brokerSelectedIssueNumber = 52
        brokerSelectedIssueUrl = 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52'
        brokerSelectedIssueTitle = '[comparevi]: template consumer rail'
        brokerProviderId = 'local-codex'
        brokerSlotId = 'slot-template-1'
        brokerSelectionSource = 'released-waiting-state-marketplace'
        ownerDecisionSource = 'compare-governor-summary'
        templateMonitoringStatus = 'pass'
        supportedProofStatus = 'pass'
        repoGraphStatus = 'pass'
        queueHandoffStatus = $null
        queueHandoffNextWakeCondition = $null
        queueHandoffPrUrl = $null
        queueAuthoritySource = $null
        viHistoryDistributorDependencyStatus = 'blocked'
        viHistoryDistributorDependencyTargetRepository = 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
        viHistoryDistributorDependencyExternalBlocker = 'workflow-signing-secret-missing'
        viHistoryDistributorDependencyPublicationState = 'unobserved'
        viHistoryDistributorDependencyPublishedBundleState = 'producer-native-incomplete'
        viHistoryDistributorDependencyPublishedBundleReleaseTag = 'v0.6.3-tools.14'
        viHistoryDistributorDependencyAuthoritativeConsumerPin = $null
        portfolioWakeConditionCount = 3
        triggeredWakeConditions = @(
          'compare-queue-not-empty',
          'compare-continuity-not-safe-idle',
          'compare-template-pivot-not-ready'
        )
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'autonomous-governor-portfolio-summary.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Governor portfolio summary'
    $output | Should -Match 'mode\s+: compare-governance-work'
    $output | Should -Match 'proof\s+: pass'
    $output | Should -Match 'vhist\s+: blocked'
    $output | Should -Match 'vhistRepo: LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    $output | Should -Match 'vhistBlk : workflow-signing-secret-missing'
    $output | Should -Match 'vhistPub : producer-native-incomplete'
    $output | Should -Match 'vhistTag : v0.6.3-tools.14'
    $output | Should -Match 'nextIssue: #52 \[comparevi\]: template consumer rail'
    $output | Should -Match 'issueUrl : https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52'
    $output | Should -Match 'broker\s+: local-codex'
    $output | Should -Match 'slot\s+: slot-template-1'
    $output | Should -Match 'selSrc\s+: released-waiting-state-marketplace'
    (Get-Variable -Name HandoffAutonomousGovernorPortfolioSummary -Scope Global -ValueOnly).schema | Should -Be 'priority/autonomous-governor-portfolio-summary-report@v1'

    Remove-Variable -Name HandoffAutonomousGovernorPortfolioSummary -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces context concentrator summary when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'priority/sagan-context-concentrator-report@v1'
      generatedAt = '2026-03-23T23:25:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      inputs = [ordered]@{
        priorityCachePath = '.agent_priority_cache.json'
        governorSummaryPath = 'tests/results/_agent/handoff/autonomous-governor-summary.json'
        governorPortfolioSummaryPath = 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json'
        monitoringModePath = 'tests/results/_agent/handoff/monitoring-mode.json'
        operatorSteeringEventPath = 'tests/results/_agent/handoff/operator-steering-event.json'
        episodeDirectoryPath = 'tests/results/_agent/memory/subagent-episodes'
      }
      sources = [ordered]@{
        priorityCache = [ordered]@{ path = '.agent_priority_cache.json'; exists = $true }
        governorSummary = [ordered]@{ path = 'tests/results/_agent/handoff/autonomous-governor-summary.json'; exists = $true }
        governorPortfolioSummary = [ordered]@{ path = 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json'; exists = $true }
        monitoringMode = [ordered]@{ path = 'tests/results/_agent/handoff/monitoring-mode.json'; exists = $true }
        operatorSteeringEvent = [ordered]@{ path = 'tests/results/_agent/handoff/operator-steering-event.json'; exists = $false }
        episodeDirectory = [ordered]@{
          path = 'tests/results/_agent/memory/subagent-episodes'
          exists = $true
          fileCount = 2
          validEpisodeCount = 2
          invalidEpisodeCount = 0
        }
      }
      focus = [ordered]@{
        activeIssue = [ordered]@{
          number = 1909
          title = '[governor]: build Sagan context concentrator for durable subagent memory'
          url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
          state = 'OPEN'
          repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        }
        currentOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextAction = 'merge concentrator handoff support'
        brokerSelectedIssueNumber = 52
        brokerSelectedIssueUrl = 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52'
        brokerSelectedIssueTitle = '[comparevi]: template consumer rail'
        brokerProviderId = 'local-codex'
        brokerSlotId = 'slot-template-1'
        brokerSelectionSource = 'released-waiting-state-marketplace'
        governorMode = 'compare-governance-work'
        monitoringStatus = 'active'
      }
      memory = [ordered]@{
        hotWorkingSet = @(
          [ordered]@{
            id = 'issue-1909'
            kind = 'active-issue'
            label = '#1909: [governor]: build Sagan context concentrator for durable subagent memory'
            status = 'OPEN'
            detail = 'Current standing-priority objective'
            sourcePath = '.agent_priority_cache.json'
            updatedAt = '2026-03-23T23:24:00Z'
            issueNumber = 1909
            repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
            agentName = $null
            nextAction = 'merge concentrator handoff support'
          }
        )
        warmMemory = @()
        archiveCount = 1
      }
      episodes = [ordered]@{
        totalCount = 2
        validCount = 2
        invalidCount = 0
        invalidEpisodes = @()
        byStatus = @([ordered]@{ status = 'reported'; count = 2 })
        byAgent = @([ordered]@{ agentId = 'euler-id'; agentName = 'Euler'; count = 1 })
        recent = @()
      }
      cost = [ordered]@{
        episodeCountWithCost = 2
        tokenUsd = 0.12
        operatorLaborUsd = 10.416667
        blendedLowerBoundUsd = 10.536667
        observedDurationSeconds = 150
      }
      summary = [ordered]@{
        status = 'active'
        concentrationStatus = 'pass'
        currentOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextOwnerRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        nextAction = 'merge concentrator handoff support'
        brokerSelectedIssueNumber = 52
        brokerSelectedIssueUrl = 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52'
        brokerSelectedIssueTitle = '[comparevi]: template consumer rail'
        brokerProviderId = 'local-codex'
        brokerSlotId = 'slot-template-1'
        brokerSelectionSource = 'released-waiting-state-marketplace'
        activeIssueNumber = 1909
        hotWorkingSetCount = 1
        warmMemoryCount = 0
        archiveCount = 1
        blockerCount = 0
        recentEpisodeCount = 2
        blendedLowerBoundUsd = 10.536667
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'sagan-context-concentrator.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Context concentrator'
    $output | Should -Match 'issue\s+: #1909'
    $output | Should -Match 'nextIssue: #52 \[comparevi\]: template consumer rail'
    $output | Should -Match 'broker\s+: local-codex'
    $output | Should -Match 'slot\s+: slot-template-1'
    $output | Should -Match 'selSrc\s+: released-waiting-state-marketplace'
    $output | Should -Match 'hot/warm\s+: 1/0'
    (Get-Variable -Name HandoffContextConcentrator -Scope Global -ValueOnly).schema | Should -Be 'priority/sagan-context-concentrator-report@v1'

    Remove-Variable -Name HandoffContextConcentrator -Scope Global -ErrorAction SilentlyContinue
  }
}
