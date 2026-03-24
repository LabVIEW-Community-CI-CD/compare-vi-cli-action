import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  parseArgs,
  runAutonomousGovernorSummary
} from '../autonomous-governor-summary.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createMonitoringMode() {
  return {
    schema: 'agent-handoff/monitoring-mode-v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    compare: {
      queueState: { status: 'queue-empty', detail: 'queue-empty', ready: true },
      continuity: { status: 'maintained', detail: 'safe-idle', ready: true }
    },
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0
    }
  };
}

function createContinuitySummary() {
  return {
    schema: 'priority/continuity-telemetry-report@v1',
    status: 'maintained',
    continuity: {
      turnBoundary: {
        status: 'safe-idle',
        supervisionState: 'safe-idle',
        operatorPromptRequiredToResume: false
      }
    }
  };
}

function createQueueEmpty() {
  return {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 11
  };
}

function createWakeLifecycle() {
  return {
    schema: 'priority/wake-lifecycle-report@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    wake: {
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    summary: {
      terminalState: 'compare-work',
      currentStage: 'monitoring-work-injection',
      wakeClassification: 'branch-target-drift',
      decision: 'compare-governance-work',
      monitoringStatus: 'would-create-issue',
      authoritativeTier: 'authoritative',
      blockedLowerTierEvidence: true,
      replayMatched: false,
      replayAuthorityCompatible: false,
      issueNumber: null,
      issueUrl: null
    }
  };
}

function createWakeInvestmentAccounting() {
  return {
    schema: 'priority/wake-investment-accounting-report@v1',
    billingWindow: {
      invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
      fundingPurpose: 'operational',
      activationState: 'active'
    },
    summary: {
      accountingBucket: 'compare-governance-work',
      status: 'warn',
      paybackStatus: 'neutral',
      recommendation: 'continue-estimated-telemetry',
      metrics: {
        benchmarkIssueUsd: 0.0201,
        observedWakeIssueUsd: 0.0201,
        netPaybackUsd: 0
      }
    }
  };
}

function createReleaseSigningReadiness(overrides = {}) {
  return {
    schema: 'priority/release-signing-readiness-report@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    workflowContract: {
      ready: true,
      workflowPath: '.github/workflows/release-conductor.yml',
      reasons: []
    },
    secretInventory: {
      status: 'missing',
      requiredSecretPresent: false,
      optionalPublicKeyPresent: false,
      listedSecretCount: 3,
      listedSecretNames: ['AUTO_APPROVE_TOKEN', 'GH_POLICY_TOKEN', 'GH_TOKEN'],
      source: 'github-actions-secrets-api',
      error: null
    },
    releaseConductorApply: {
      status: 'disabled',
      variablePresent: false,
      enabled: false,
      configuredValue: null,
      listedVariableCount: 0,
      listedVariableNames: [],
      source: 'github-actions-variables-api',
      error: null
    },
    signingAuthority: {
      status: 'scope-missing',
      requiredScope: 'admin:ssh_signing_key',
      scopeAvailable: false,
      listedKeyCount: null,
      source: 'github-user-ssh-signing-keys-api',
      error: 'This API operation needs the \"admin:ssh_signing_key\" scope.'
    },
    publication: {
      status: 'tag-created-not-pushed',
      tagCreated: true,
      tagPushed: false,
      targetTag: 'v0.6.4-rc.1'
    },
    summary: {
      status: 'warn',
      codePathState: 'ready',
      signingCapabilityState: 'missing',
      signingAuthorityState: 'scope-missing',
      releaseConductorApplyState: 'disabled',
      publicationState: 'tag-created-not-pushed',
      publishedBundleState: 'producer-native-incomplete',
      publishedBundleReleaseTag: 'v0.6.3-tools.14',
      publishedBundleAuthoritativeConsumerPin: null,
      externalBlocker: 'workflow-signing-secret-missing',
      blockerCount: 3
    },
    blockers: [
      {
        code: 'workflow-signing-secret-missing',
        message: 'RELEASE_TAG_SIGNING_PRIVATE_KEY is not configured for the repository Actions secrets surface.'
      },
      {
        code: 'release-conductor-apply-disabled',
        message: 'RELEASE_CONDUCTOR_ENABLED is not set to 1 for the repository Actions variable surface.'
      },
      {
        code: 'workflow-signing-admin-scope-missing',
        message: 'admin:ssh_signing_key is not available to the current automation identity, so SSH signing-key authority cannot be verified or managed.'
      }
    ],
    ...overrides
  };
}

function createDeliveryRuntimeState(overrides = {}) {
  return {
    schema: 'priority/delivery-agent-runtime-state@v1',
    status: 'waiting-ci',
    laneLifecycle: 'waiting-ci',
    logicalLaneActivation: {
      seededLaneCount: 4,
      activeLaneCount: 2,
      catalog: [
        { id: 'logical-lane-01', activationState: 'active' },
        { id: 'logical-lane-02', activationState: 'active' },
        { id: 'logical-lane-03', activationState: 'seeded' },
        { id: 'logical-lane-04', activationState: 'seeded' }
      ]
    },
    queueAuthorityRefresh: {
      attempted: false,
      status: null,
      reason: null,
      summaryPath: null,
      mergeSummaryPath: null,
      receiptGeneratedAt: null,
      receiptStatus: null,
      receiptReason: null,
      evidenceFreshness: null,
      nextWakeCondition: null,
      mergeStateStatus: null,
      isInMergeQueue: null,
      autoMergeEnabled: null,
      mergedAt: null
    },
    activeLane: {
      issue: 1863,
      prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
      laneLifecycle: 'waiting-ci',
      actionType: 'merge-pr',
      outcome: 'waiting-ci',
      blockerClass: 'none',
      nextWakeCondition: 'checks-green',
      reason: 'Waiting for hosted checks to finish before merge queue advances.',
      providerDispatch: {
        providerId: 'hosted-github-workflow',
        providerKind: 'hosted-github-workflow',
        executionPlane: 'hosted',
        assignmentMode: 'async-validation',
        dispatchSurface: 'github-actions',
        completionMode: 'async',
        workerSlotId: 'worker-slot-2',
        dispatchStatus: 'completed',
        completionStatus: 'waiting',
        failureClass: null
      },
      concurrentLaneStatus: {
        executionBundle: {
          status: 'committed',
          planeBinding: 'dual-plane-parity',
          harnessKind: 'teststand-compare-harness',
          premiumSaganMode: true,
          reciprocalLinkReady: true,
          effectiveBillableRateUsdPerHour: 375,
          executionCellLeaseId: 'exec-lease-123',
          dockerLaneLeaseId: 'docker-lease-456',
          harnessInstanceId: 'ts-harness-01',
          cellId: 'cell-sagan-kernel',
          laneId: 'docker-lane-01',
          isolatedLaneGroupId:
            'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        }
      }
    },
    ...overrides
  };
}

function createMergeSyncSummary(overrides = {}) {
  return {
    schema: 'priority/sync-merge@v1',
    pr: 1864,
    promotion: {
      status: 'already-queued',
      final: {
        state: 'OPEN',
        mergeStateStatus: 'CLEAN',
        isInMergeQueue: true,
        autoMergeEnabled: false,
        mergedAt: null
      }
    },
    prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
    ...overrides
  };
}

function createQueueRefreshReceipt(overrides = {}) {
  return {
    schema: 'priority/queue-refresh-receipt@v1',
    operation: 'dequeue-update-requeue',
    generatedAt: '2026-03-23T05:27:31.683Z',
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pr: 1864,
    dryRun: true,
    baseRefName: 'develop',
    headRefName: 'issue/upstream-1863-pr-create-merge-sync-handoff',
    headRepositorySlug: 'svelderrainruiz/compare-vi-cli-action',
    headRemote: 'origin',
    queueManagedBase: true,
    initial: {
      state: 'OPEN',
      mergeStateStatus: 'UNSTABLE',
      isInMergeQueue: true,
      autoMergeEnabled: false,
      mergedAt: null,
      headRefOid: '8ea4bbe3d9ea2ed1f268f52d3c32d7424d0ce76b',
      currentBranch: 'issue/upstream-1869-merge-queue-refresh'
    },
    dequeue: {
      attempted: true,
      status: 'dry-run',
      reason: 'dry-run',
      helperCallsExecuted: [],
      pullRequestId: 'PR_kwDOP5zZjs7Mks-1',
      pollAttemptsUsed: 0,
      finalIsInMergeQueue: true
    },
    refresh: {
      attempted: true,
      status: 'dry-run',
      reason: 'dry-run',
      helperCallsExecuted: [],
      mode: 'rebase',
      baseRemoteRef: 'upstream/develop',
      forcePushTarget: 'origin:issue/upstream-1863-pr-create-merge-sync-handoff',
      rebasedHeadSha: null
    },
    requeue: {
      attempted: true,
      status: 'dry-run',
      reason: 'dry-run',
      helperCallsExecuted: [],
      mergeSummaryPath: 'tests/results/_agent/queue/merge-sync-1864.json',
      promotionStatus: null,
      materialized: null,
      finalMode: null,
      finalReason: null
    },
    summary: {
      status: 'dry-run',
      reason: 'dry-run'
    },
    ...overrides
  };
}

test('parseArgs keeps governor summary defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'autonomous-governor-summary.mjs',
    '--repo-root',
    'C:/repo',
    '--output',
    'custom/summary.json'
  ]);

  assert.equal(parsed.repoRoot, 'C:/repo');
  assert.equal(parsed.outputPath, 'custom/summary.json');
  assert.equal(
    DEFAULT_OUTPUT_PATH,
    path.join('tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json')
  );
});

test('runAutonomousGovernorSummary reports compare governance work when the latest wake resolves to compare-work', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-lifecycle.json'), createWakeLifecycle());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json'),
    createWakeInvestmentAccounting()
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'compare-governance-work');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextAction, 'continue-compare-governance-work');
  assert.equal(report.summary.signalQuality, 'validated-governance-work');
  assert.equal(report.funding.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(report.compare.releaseSigningReadiness.status, 'missing');
  assert.equal(report.summary.releaseSigningStatus, 'missing');
  assert.equal(report.summary.releaseSigningExternalBlocker, null);
});

test('runAutonomousGovernorSummary reports monitoring-active when no wake lifecycle exists', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-monitoring-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'monitoring-active');
  assert.equal(report.summary.nextAction, 'future-agent-may-pivot');
  assert.equal(report.summary.signalQuality, 'idle-monitoring');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.wake.terminalState, null);
  assert.equal(report.compare.deliveryRuntime.status, 'none');
  assert.equal(report.compare.releaseSigningReadiness.status, 'missing');
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.attempted, false);
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.status, null);
  assert.equal(report.summary.queueHandoffStatus, 'none');
  assert.equal(report.summary.queueAuthoritySource, 'none');
  assert.equal(report.summary.releaseSigningStatus, 'missing');
});

test('runAutonomousGovernorSummary carries explicit release signing blocker state into the governor summary', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-release-signing-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'release', 'release-signing-readiness.json'),
    createReleaseSigningReadiness()
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.compare.releaseSigningReadiness.status, 'warn');
  assert.equal(report.compare.releaseSigningReadiness.codePathState, 'ready');
  assert.equal(report.compare.releaseSigningReadiness.signingCapabilityState, 'missing');
  assert.equal(report.compare.releaseSigningReadiness.signingAuthorityState, 'scope-missing');
  assert.equal(report.compare.releaseSigningReadiness.releaseConductorApplyState, 'disabled');
  assert.equal(report.compare.releaseSigningReadiness.publicationState, 'tag-created-not-pushed');
  assert.equal(report.compare.releaseSigningReadiness.publishedBundleState, 'producer-native-incomplete');
  assert.equal(report.compare.releaseSigningReadiness.publishedBundleReleaseTag, 'v0.6.3-tools.14');
  assert.equal(report.compare.releaseSigningReadiness.publishedBundleAuthoritativeConsumerPin, null);
  assert.equal(report.compare.releaseSigningReadiness.externalBlocker, 'workflow-signing-secret-missing');
  assert.equal(report.summary.releaseSigningStatus, 'warn');
  assert.equal(report.summary.releaseSigningAuthorityState, 'scope-missing');
  assert.equal(report.summary.releaseConductorApplyState, 'disabled');
  assert.equal(report.summary.releaseSigningExternalBlocker, 'workflow-signing-secret-missing');
  assert.equal(report.summary.releasePublicationState, 'tag-created-not-pushed');
  assert.equal(report.summary.releasePublishedBundleState, 'producer-native-incomplete');
  assert.equal(report.summary.releasePublishedBundleReleaseTag, 'v0.6.3-tools.14');
  assert.equal(report.summary.releasePublishedBundleAuthoritativeConsumerPin, null);
});

test('runAutonomousGovernorSummary carries queue-owned delivery runtime state into the governor summary', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-queue-handoff-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-lifecycle.json'), createWakeLifecycle());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json'),
    createWakeInvestmentAccounting()
  );
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'),
    createDeliveryRuntimeState()
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.compare.deliveryRuntime.status, 'checks-pending');
  assert.equal(report.compare.deliveryRuntime.laneLifecycle, 'waiting-ci');
  assert.equal(report.compare.deliveryRuntime.nextWakeCondition, 'checks-green');
  assert.equal(report.compare.deliveryRuntime.prUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864');
  assert.equal(report.compare.deliveryRuntime.executionTopology.status, 'bundle-committed');
  assert.equal(report.compare.deliveryRuntime.executionTopology.executionPlane, 'hosted');
  assert.equal(report.compare.deliveryRuntime.executionTopology.providerId, 'hosted-github-workflow');
  assert.equal(report.compare.deliveryRuntime.executionTopology.workerSlotId, 'worker-slot-2');
  assert.equal(report.compare.deliveryRuntime.executionTopology.activeLogicalLaneCount, 2);
  assert.equal(report.compare.deliveryRuntime.executionTopology.seededLogicalLaneCount, 4);
  assert.equal(report.compare.deliveryRuntime.executionTopology.catalogCount, 4);
  assert.equal(report.compare.deliveryRuntime.executionTopology.runtimeSurface, 'windows-native-teststand');
  assert.equal(report.compare.deliveryRuntime.executionTopology.processModelClass, 'parallel-process-model');
  assert.equal(report.compare.deliveryRuntime.executionTopology.windowsOnly, true);
  assert.equal(report.compare.deliveryRuntime.executionTopology.requestedSimultaneous, true);
  assert.equal(report.compare.deliveryRuntime.executionTopology.logicalLaneActivation.activeLaneCount, 2);
  assert.equal(report.compare.deliveryRuntime.executionTopology.providerDispatch.dispatchStatus, 'completed');
  assert.equal(report.compare.deliveryRuntime.executionTopology.executionBundle.status, 'committed');
  assert.equal(report.compare.deliveryRuntime.executionBundle.status, 'committed');
  assert.equal(report.compare.deliveryRuntime.executionBundle.planeBinding, 'dual-plane-parity');
  assert.equal(report.compare.deliveryRuntime.executionBundle.premiumSaganMode, true);
  assert.equal(report.compare.deliveryRuntime.executionBundle.reciprocalLinkReady, true);
  assert.equal(report.compare.deliveryRuntime.executionBundle.effectiveBillableRateUsdPerHour, 375);
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.attempted, false);
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.summaryPath, null);
  assert.equal(report.summary.executionTopologyStatus, 'bundle-committed');
  assert.equal(report.summary.executionTopologyExecutionPlane, 'hosted');
  assert.equal(report.summary.executionTopologyProviderId, 'hosted-github-workflow');
  assert.equal(report.summary.executionTopologyWorkerSlotId, 'worker-slot-2');
  assert.equal(report.summary.executionTopologyActiveLogicalLaneCount, 2);
  assert.equal(report.summary.executionTopologySeededLogicalLaneCount, 4);
  assert.equal(report.summary.executionTopologyRuntimeSurface, 'windows-native-teststand');
  assert.equal(report.summary.executionTopologyProcessModelClass, 'parallel-process-model');
  assert.equal(report.summary.executionTopologyWindowsOnly, true);
  assert.equal(report.summary.executionTopologyRequestedSimultaneous, true);
  assert.equal(report.summary.executionBundleStatus, 'committed');
  assert.equal(report.summary.executionBundlePlaneBinding, 'dual-plane-parity');
  assert.equal(report.summary.executionBundlePremiumSaganMode, true);
  assert.equal(report.summary.executionBundleReciprocalLinkReady, true);
  assert.equal(report.summary.executionBundleEffectiveBillableRateUsdPerHour, 375);
  assert.equal(report.summary.queueHandoffStatus, 'checks-pending');
  assert.equal(report.summary.queueHandoffNextWakeCondition, 'checks-green');
  assert.equal(report.summary.queueHandoffPrUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864');
  assert.equal(report.summary.queueAuthoritySource, 'delivery-runtime');
});

test('runAutonomousGovernorSummary exposes queue authority refresh telemetry from delivery runtime state', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-runtime-refresh-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'),
    createDeliveryRuntimeState({
      queueAuthorityRefresh: {
        attempted: true,
        status: 'completed',
        reason: 'queue-refresh-dry-run',
        summaryPath: 'tests/results/_agent/queue/queue-refresh-1864.json',
        mergeSummaryPath: 'tests/results/_agent/queue/merge-sync-1864.json',
        receiptGeneratedAt: '2026-03-23T05:27:31.683Z',
        receiptStatus: 'dry-run',
        receiptReason: 'dry-run',
        evidenceFreshness: 'current',
        nextWakeCondition: 'merge-queue-progress',
        mergeStateStatus: 'UNSTABLE',
        isInMergeQueue: true,
        autoMergeEnabled: false,
        mergedAt: null
      },
      activeLane: {
        issue: 1863,
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
        laneLifecycle: 'waiting-ci',
        actionType: 'merge-pr',
        outcome: 'waiting-ci',
        blockerClass: 'none',
        nextWakeCondition: 'checks-green',
        reason: 'Waiting for hosted checks to finish before merge queue advances.',
        queueAuthorityRefresh: {
          attempted: true,
          status: 'completed',
          reason: 'queue-refresh-dry-run',
          summaryPath: 'tests/results/_agent/queue/queue-refresh-1864.json',
          mergeSummaryPath: 'tests/results/_agent/queue/merge-sync-1864.json',
          receiptGeneratedAt: '2026-03-23T05:27:31.683Z',
          receiptStatus: 'dry-run',
          receiptReason: 'dry-run',
          evidenceFreshness: 'current',
          nextWakeCondition: 'merge-queue-progress',
          mergeStateStatus: 'UNSTABLE',
          isInMergeQueue: true,
          autoMergeEnabled: false,
          mergedAt: null
        }
      }
    })
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.attempted, true);
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.status, 'completed');
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.summaryPath, 'tests/results/_agent/queue/queue-refresh-1864.json');
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.mergeSummaryPath, 'tests/results/_agent/queue/merge-sync-1864.json');
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.receiptStatus, 'dry-run');
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.evidenceFreshness, 'current');
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.isInMergeQueue, true);
  assert.equal(report.compare.deliveryRuntime.queueAuthorityRefresh.autoMergeEnabled, false);
});

test('runAutonomousGovernorSummary prefers merge-sync queue evidence when it proves the PR is already queued', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-queue-authority-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-lifecycle.json'), createWakeLifecycle());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json'),
    createWakeInvestmentAccounting()
  );
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'),
    createDeliveryRuntimeState({
      activeLane: {
        issue: 1863,
        prUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
        laneLifecycle: 'waiting-ci',
        actionType: 'merge-pr',
        outcome: 'waiting-ci',
        blockerClass: 'none',
        nextWakeCondition: 'checks-green',
        reason: 'Waiting for hosted checks to finish before merge queue advances.'
      }
    })
  );
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-1864-queue-admission.json'),
    createMergeSyncSummary()
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.compare.queueAuthority.status, 'merge-queue-progress');
  assert.equal(report.compare.queueAuthority.source, 'merge-sync-summary');
  assert.equal(
    report.compare.queueAuthority.summaryPath,
    'tests/results/_agent/issue/LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-1864-queue-admission.json'
  );
  assert.equal(report.compare.queueAuthority.promotionStatus, 'already-queued');
  assert.equal(report.compare.queueAuthority.isInMergeQueue, true);
  assert.equal(report.summary.queueHandoffStatus, 'merge-queue-progress');
  assert.equal(report.summary.queueHandoffNextWakeCondition, 'merge-queue-progress');
  assert.equal(report.summary.queueAuthoritySource, 'merge-sync-summary');
});

test('runAutonomousGovernorSummary prefers fresher queue-refresh evidence over older merge-sync state', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-queue-refresh-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), createQueueEmpty());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), createContinuitySummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-lifecycle.json'), createWakeLifecycle());
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'capital', 'wake-investment-accounting.json'),
    createWakeInvestmentAccounting()
  );
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'),
    createDeliveryRuntimeState()
  );
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'LabVIEW-Community-CI-CD-compare-vi-cli-action-pr-1864-queue-admission.json'),
    createMergeSyncSummary({
      promotion: {
        status: 'already-auto-merge-enabled',
        final: {
          state: 'OPEN',
          mergeStateStatus: 'BLOCKED',
          isInMergeQueue: false,
          autoMergeEnabled: true,
          mergedAt: null
        }
      }
    })
  );
  writeJson(
    path.join(tmpDir, 'tests', 'results', '_agent', 'queue', 'queue-refresh-1864.json'),
    createQueueRefreshReceipt()
  );

  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir });

  assert.equal(report.compare.queueAuthority.status, 'merge-queue-progress');
  assert.equal(report.compare.queueAuthority.source, 'queue-refresh-summary');
  assert.equal(report.compare.queueAuthority.summaryPath, 'tests/results/_agent/queue/queue-refresh-1864.json');
  assert.equal(report.compare.queueAuthority.mergeStateStatus, 'UNSTABLE');
  assert.equal(report.compare.queueAuthority.isInMergeQueue, true);
  assert.equal(report.summary.queueHandoffStatus, 'merge-queue-progress');
  assert.equal(report.summary.queueAuthoritySource, 'queue-refresh-summary');
});
