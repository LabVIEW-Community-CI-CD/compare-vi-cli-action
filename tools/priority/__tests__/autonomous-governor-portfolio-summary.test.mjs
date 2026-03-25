import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_COMPARE_GOVERNOR_SUMMARY_PATH,
  DEFAULT_MONITORING_MODE_PATH,
  DEFAULT_OUTPUT_PATH,
  DEFAULT_REPO_GRAPH_TRUTH_PATH,
  parseArgs,
  runAutonomousGovernorPortfolioSummary
} from '../autonomous-governor-portfolio-summary.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createCompareGovernorSummary(overrides = {}) {
  return {
    schema: 'priority/autonomous-governor-summary-report@v1',
    generatedAt: '2026-03-22T22:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      queueEmptyReportPath: 'tests/results/_agent/issue/no-standing-priority.json',
      continuitySummaryPath: 'tests/results/_agent/handoff/continuity-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      wakeLifecyclePath: 'tests/results/_agent/issue/wake-lifecycle.json',
      wakeInvestmentAccountingPath: 'tests/results/_agent/capital/wake-investment-accounting.json'
    },
    compare: {
      queueState: { status: 'not-queue-empty', reason: 'standing-open', openIssueCount: 1, ready: false },
      continuity: {
        status: 'at-risk',
        turnBoundary: 'active-work-pending',
        supervisionState: 'issue',
        operatorPromptRequiredToResume: true
      },
      monitoringMode: {
        status: 'blocked',
        futureAgentAction: 'stay-in-compare-monitoring',
        wakeConditionCount: 3
      },
      releaseSigningReadiness: {
        status: 'warn',
        codePathState: 'ready',
        signingCapabilityState: 'missing',
        signingAuthorityState: 'scope-missing',
        releaseConductorApplyState: 'disabled',
        publicationState: 'unobserved',
        publishedBundleState: 'producer-native-incomplete',
        publishedBundleReleaseTag: 'v0.6.3-tools.14',
        publishedBundleAuthoritativeConsumerPin: null,
        externalBlocker: 'workflow-signing-secret-missing'
      },
      deliveryRuntime: {
        executionTopology: {
          status: 'bundle-committed',
          executionPlane: 'hosted',
          providerId: 'hosted-github-workflow',
          workerSlotId: 'worker-slot-2',
          activeLogicalLaneCount: 2,
          seededLogicalLaneCount: 4,
          catalogCount: 4,
          runtimeSurface: 'windows-native-teststand',
          processModelClass: 'parallel-process-model',
          windowsOnly: true,
          requestedSimultaneous: true,
          cellClass: 'kernel-coordinator',
          suiteClass: 'dual-plane-parity',
          operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
          premiumSaganMode: true,
          reciprocalLinkReady: true,
          logicalLaneActivation: {
            activeLaneCount: 2,
            seededLaneCount: 4,
            catalogCount: 4
          },
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
          executionBundle: {
            status: 'committed',
            planeBinding: 'dual-plane-parity',
            cellClass: 'kernel-coordinator',
            suiteClass: 'dual-plane-parity',
            harnessKind: 'teststand-compare-harness',
            premiumSaganMode: true,
            reciprocalLinkReady: true,
            effectiveBillableRateUsdPerHour: 375,
            executionCellLeaseId: 'exec-lease-123',
            dockerLaneLeaseId: 'docker-lease-456',
            harnessInstanceId: 'ts-harness-01',
            operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
            cellId: 'cell-sagan-kernel',
            laneId: 'docker-lane-01',
            isolatedLaneGroupId:
              'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
          }
        }
      }
    },
    wake: {
      terminalState: 'compare-work',
      currentStage: 'monitoring-work-injection',
      classification: 'branch-target-drift',
      decision: 'compare-governance-work',
      monitoringStatus: 'would-create-issue',
      authoritativeTier: 'authoritative',
      blockedLowerTierEvidence: true,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: 1845,
      issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1845',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    funding: {
      accountingBucket: 'compare-governance-work',
      status: 'warn',
      paybackStatus: 'neutral',
      recommendation: 'continue-estimated-telemetry',
      invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
      fundingPurpose: 'operational',
      activationState: 'active',
      benchmarkIssueUsd: 0.12,
      observedWakeIssueUsd: 0.02,
      netPaybackUsd: 0
    },
    summary: {
      governorMode: 'compare-governance-work',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'continue-compare-governance-work',
      signalQuality: 'validated-governance-work',
      queueState: 'not-queue-empty',
      continuityStatus: 'at-risk',
      wakeTerminalState: 'compare-work',
      monitoringStatus: 'blocked',
      futureAgentAction: 'stay-in-compare-monitoring',
      queueHandoffStatus: 'checks-pending',
      queueHandoffNextWakeCondition: 'checks-green',
      queueHandoffPrUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864',
      queueAuthoritySource: 'delivery-runtime',
      executionTopologyStatus: 'bundle-committed',
      executionTopologyExecutionPlane: 'hosted',
      executionTopologyProviderId: 'hosted-github-workflow',
      executionTopologyWorkerSlotId: 'worker-slot-2',
      executionTopologyActiveLogicalLaneCount: 2,
      executionTopologySeededLogicalLaneCount: 4,
      executionTopologyRuntimeSurface: 'windows-native-teststand',
      executionTopologyProcessModelClass: 'parallel-process-model',
      executionTopologyWindowsOnly: true,
      executionTopologyRequestedSimultaneous: true,
      executionTopologyCellClass: 'kernel-coordinator',
      executionTopologySuiteClass: 'dual-plane-parity',
      executionTopologyOperatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
      executionBundleStatus: 'committed',
      executionBundlePlaneBinding: 'dual-plane-parity',
      executionBundlePremiumSaganMode: true,
      executionBundleReciprocalLinkReady: true,
      executionBundleEffectiveBillableRateUsdPerHour: 375,
      releaseSigningStatus: 'warn',
      releaseSigningAuthorityState: 'scope-missing',
      releaseConductorApplyState: 'disabled',
      releaseSigningExternalBlocker: 'workflow-signing-secret-missing',
      releasePublicationState: 'unobserved',
      releasePublishedBundleState: 'producer-native-incomplete',
      releasePublishedBundleReleaseTag: 'v0.6.3-tools.14',
      releasePublishedBundleAuthoritativeConsumerPin: null
    },
    ...overrides
  };
}

function createMonitoringMode(overrides = {}) {
  return {
    schema: 'agent-handoff/monitoring-mode-v1',
    generatedAt: '2026-03-22T22:01:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/template-monitoring.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      repoGraphPolicyPath: 'tools/policy/downstream-repo-graph.json',
      wakeConditions: []
    },
    compare: {
      queueState: { reportPath: 'tests/results/_agent/issue/no-standing-priority.json', ready: false, status: 'not-queue-empty', detail: 'standing-open' },
      continuity: { reportPath: 'tests/results/_agent/handoff/continuity-summary.json', ready: false, status: 'at-risk', detail: 'active-work-pending' },
      pivotGate: { reportPath: 'tests/results/_agent/promotion/template-pivot-gate-report.json', ready: false, status: 'blocked', detail: 'queue-not-empty' },
      readyForMonitoring: false
    },
    repoGraph: {
      reportPath: 'tests/results/_agent/handoff/downstream-repo-graph-truth.json',
      ready: true,
      status: 'pass',
      detail: 'roles=7'
    },
    templateMonitoring: {
      status: 'pass',
      repositories: [
        {
          role: 'canonical-template',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: null,
          supportedProof: null
        },
        {
          role: 'org-consumer-fork',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: {
            status: 'pass',
            branch: 'develop',
            headSha: 'abc123',
            canonicalHeadSha: 'abc123'
          },
          supportedProof: {
            status: 'pass',
            workflowFile: 'template-smoke.yml',
            event: 'workflow_dispatch',
            requiredConclusion: 'success',
            runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/1',
            headSha: 'abc123',
            conclusion: 'success'
          }
        },
        {
          role: 'personal-consumer-fork',
          repository: 'svelderrainruiz/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: {
            status: 'pass',
            branch: 'develop',
            headSha: 'abc123',
            canonicalHeadSha: 'abc123'
          },
          supportedProof: {
            status: 'pass',
            workflowFile: 'template-smoke.yml',
            event: 'workflow_dispatch',
            requiredConclusion: 'success',
            runUrl: 'https://github.com/svelderrainruiz/LabviewGitHubCiTemplate/actions/runs/2',
            headSha: 'abc123',
            conclusion: 'success'
          }
        }
      ],
      unsupportedPaths: [
        {
          name: 'fork-local-pr-validation',
          status: 'unsupported',
          message: 'Unsupported by policy.'
        }
      ]
    },
    wakeConditions: [],
    summary: {
      status: 'blocked',
      futureAgentAction: 'stay-in-compare-monitoring',
      wakeConditionCount: 3,
      triggeredWakeConditions: [
        'compare-queue-not-empty',
        'compare-continuity-not-safe-idle',
        'compare-template-pivot-not-ready'
      ]
    },
    ...overrides
  };
}

function createRepoGraphTruth() {
  return {
    schema: 'priority/downstream-repo-graph-truth@v1',
    generatedAt: '2026-03-22T22:02:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/downstream-repo-graph.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repositories: [
      {
        id: 'compare',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        kind: 'supervisor',
        status: 'pass',
        roles: [{ id: 'compare-producer-lineage' }, { id: 'compare-consumer-proving-source' }],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      },
      {
        id: 'canonical-template',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        kind: 'canonical-template',
        status: 'pass',
        roles: [{ id: 'template-canonical-development' }, { id: 'template-consumer-proving-rail' }, { id: 'template-upstream-producer-lineage' }],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      },
      {
        id: 'org-consumer-fork',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
        kind: 'consumer-fork',
        status: 'pass',
        roles: [{ id: 'org-fork-canonical-development' }],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      },
      {
        id: 'personal-consumer-fork',
        repository: 'svelderrainruiz/LabviewGitHubCiTemplate',
        kind: 'consumer-fork',
        status: 'pass',
        roles: [{ id: 'personal-fork-canonical-development' }],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      }
    ],
    summary: {
      status: 'pass',
      repositoryCount: 4,
      roleCount: 7,
      requiredMissingRoleCount: 0,
      optionalMissingRoleCount: 0,
      alignmentFailureCount: 0,
      unknownRoleCount: 0
    }
  };
}

test('parseArgs keeps portfolio defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'autonomous-governor-portfolio-summary.mjs',
    '--compare-governor-summary',
    'compare.json',
    '--monitoring-mode',
    'monitoring.json',
    '--repo-graph-truth',
    'repo-graph.json',
    '--output',
    'portfolio.json'
  ]);

  assert.equal(parsed.compareGovernorSummaryPath, 'compare.json');
  assert.equal(parsed.monitoringModePath, 'monitoring.json');
  assert.equal(parsed.repoGraphTruthPath, 'repo-graph.json');
  assert.equal(parsed.outputPath, 'portfolio.json');
  assert.match(DEFAULT_COMPARE_GOVERNOR_SUMMARY_PATH, /autonomous-governor-summary\.json$/);
  assert.match(DEFAULT_MONITORING_MODE_PATH, /monitoring-mode\.json$/);
  assert.match(DEFAULT_REPO_GRAPH_TRUTH_PATH, /downstream-repo-graph-truth\.json$/);
  assert.match(DEFAULT_OUTPUT_PATH, /autonomous-governor-portfolio-summary\.json$/);
});

test('runAutonomousGovernorPortfolioSummary keeps compare as owner during active compare governance work', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-portfolio-compare-'));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'), createCompareGovernorSummary());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), createMonitoringMode());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'downstream-repo-graph-truth.json'), createRepoGraphTruth());

  const { report, outputPath } = await runAutonomousGovernorPortfolioSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'compare-governance-work');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextAction, 'continue-compare-governance-work');
  assert.equal(report.summary.ownerDecisionSource, 'compare-governor-summary');
  assert.equal(report.summary.queueHandoffStatus, 'checks-pending');
  assert.equal(report.summary.queueHandoffNextWakeCondition, 'checks-green');
  assert.equal(report.summary.queueAuthoritySource, 'delivery-runtime');
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
  assert.equal(report.summary.executionTopologyCellClass, 'kernel-coordinator');
  assert.equal(report.summary.executionTopologySuiteClass, 'dual-plane-parity');
  assert.equal(report.summary.executionTopologyOperatorAuthorizationRef, 'budget-auth://operator/session-2026-03-24');
  assert.equal(report.summary.executionBundleStatus, 'committed');
  assert.equal(report.summary.executionBundlePlaneBinding, 'dual-plane-parity');
  assert.equal(report.summary.executionBundlePremiumSaganMode, true);
  assert.equal(report.summary.executionBundleReciprocalLinkReady, true);
  assert.equal(report.summary.executionBundleEffectiveBillableRateUsdPerHour, 375);
  assert.equal(report.summary.viHistoryDistributorDependencyStatus, 'blocked');
  assert.equal(
    report.summary.viHistoryDistributorDependencyExternalBlocker,
    'workflow-signing-secret-missing'
  );
  assert.equal(report.summary.viHistoryDistributorDependencyPublicationState, 'unobserved');
  assert.equal(report.summary.viHistoryDistributorDependencyPublishedBundleState, 'producer-native-incomplete');
  assert.equal(report.summary.viHistoryDistributorDependencyPublishedBundleReleaseTag, 'v0.6.3-tools.14');
  assert.equal(report.summary.viHistoryDistributorDependencyAuthoritativeConsumerPin, null);
  assert.equal(report.summary.viHistoryDistributorDependencySigningAuthorityState, 'scope-missing');
  assert.equal(report.summary.viHistoryDistributorDependencyReleaseConductorApplyState, 'disabled');
  assert.equal(report.compare.queueHandoffPrUrl, 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1864');
  assert.equal(report.compare.queueAuthoritySource, 'delivery-runtime');
  assert.equal(report.compare.executionTopology.status, 'bundle-committed');
  assert.equal(report.compare.executionTopology.executionPlane, 'hosted');
  assert.equal(report.compare.executionTopology.providerId, 'hosted-github-workflow');
  assert.equal(report.compare.executionTopology.workerSlotId, 'worker-slot-2');
  assert.equal(report.compare.executionTopology.activeLogicalLaneCount, 2);
  assert.equal(report.compare.executionTopology.seededLogicalLaneCount, 4);
  assert.equal(report.compare.executionTopology.runtimeSurface, 'windows-native-teststand');
  assert.equal(report.compare.executionTopology.processModelClass, 'parallel-process-model');
  assert.equal(report.compare.executionTopology.windowsOnly, true);
  assert.equal(report.compare.executionTopology.requestedSimultaneous, true);
  assert.equal(report.compare.executionTopology.cellClass, 'kernel-coordinator');
  assert.equal(report.compare.executionTopology.suiteClass, 'dual-plane-parity');
  assert.equal(report.compare.executionTopology.operatorAuthorizationRef, 'budget-auth://operator/session-2026-03-24');
  assert.equal(report.compare.executionTopology.logicalLaneActivation.catalogCount, 4);
  assert.equal(report.compare.executionTopology.providerDispatch.dispatchStatus, 'completed');
  assert.equal(report.compare.executionTopology.executionBundle.status, 'committed');
  assert.equal(report.compare.executionTopology.executionBundle.cellClass, 'kernel-coordinator');
  assert.equal(report.compare.executionTopology.executionBundle.suiteClass, 'dual-plane-parity');
  assert.equal(
    report.compare.executionTopology.executionBundle.operatorAuthorizationRef,
    'budget-auth://operator/session-2026-03-24'
  );
  assert.equal(report.compare.executionBundleStatus, 'committed');
  assert.equal(report.compare.executionBundlePlaneBinding, 'dual-plane-parity');
  assert.equal(report.compare.executionBundlePremiumSaganMode, true);
  assert.equal(report.compare.executionBundleReciprocalLinkReady, true);
  assert.equal(report.compare.executionBundleEffectiveBillableRateUsdPerHour, 375);
  assert.equal(report.portfolio.repositoryCount, 4);
  assert.deepEqual(report.portfolio.dependencies, [
    {
      id: 'vi-history-producer-native-distributor',
      status: 'blocked',
      ownerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      dependentRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      requiredCapability: 'vi-history',
      source: 'compare-release-signing-readiness',
      releaseSigningStatus: 'warn',
      releasePublicationState: 'unobserved',
      publishedBundleState: 'producer-native-incomplete',
      publishedBundleReleaseTag: 'v0.6.3-tools.14',
      publishedBundleAuthoritativeConsumerPin: null,
      signingCapabilityState: 'missing',
      signingAuthorityState: 'scope-missing',
      releaseConductorApplyState: 'disabled',
      externalBlocker: 'workflow-signing-secret-missing',
      detail: 'awaiting-producer-native-bundle-publication'
    }
  ]);
  assert.deepEqual(report.portfolio.repositories.find((entry) => entry.id === 'compare').triggeredWakeConditions, [
    'compare-queue-not-empty',
    'compare-continuity-not-safe-idle',
    'compare-template-pivot-not-ready'
  ]);
  assert.equal(report.summary.templateMonitoringStatus, 'pass');
  assert.equal(report.summary.supportedProofStatus, 'pass');
  assert.match(outputPath, /autonomous-governor-portfolio-summary\.json$/);
});

test('runAutonomousGovernorPortfolioSummary routes ownership to canonical template when monitoring reopens template work', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-portfolio-template-'));
  const compareSummary = createCompareGovernorSummary({
    compare: {
      queueState: { status: 'queue-empty', reason: 'queue-empty', openIssueCount: 0, ready: true },
      continuity: {
        status: 'maintained',
        turnBoundary: 'safe-idle',
        supervisionState: 'idle-monitoring',
        operatorPromptRequiredToResume: false
      },
      monitoringMode: {
        status: 'blocked',
        futureAgentAction: 'reopen-template-monitoring-work',
        wakeConditionCount: 1
      },
      releaseSigningReadiness: {
        status: 'warn',
        codePathState: 'ready',
        signingCapabilityState: 'missing',
        signingAuthorityState: 'scope-missing',
        releaseConductorApplyState: 'disabled',
        publicationState: 'unobserved',
        externalBlocker: 'workflow-signing-secret-missing'
      }
    },
    wake: {
      terminalState: 'monitoring',
      currentStage: 'monitoring',
      classification: null,
      decision: null,
      monitoringStatus: 'blocked',
      authoritativeTier: null,
      blockedLowerTierEvidence: false,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: null,
      issueUrl: null,
      recommendedOwnerRepository: null
    },
    summary: {
      governorMode: 'monitoring-active',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'reopen-template-monitoring-work',
      signalQuality: 'idle-monitoring',
      queueState: 'queue-empty',
      continuityStatus: 'maintained',
      wakeTerminalState: 'monitoring',
      monitoringStatus: 'blocked',
      futureAgentAction: 'reopen-template-monitoring-work',
      releaseSigningStatus: 'warn',
      releaseSigningAuthorityState: 'scope-missing',
      releaseConductorApplyState: 'disabled',
      releaseSigningExternalBlocker: 'workflow-signing-secret-missing',
      releasePublicationState: 'unobserved',
      queueHandoffStatus: 'none',
      queueHandoffNextWakeCondition: null,
      queueHandoffPrUrl: null,
      queueAuthoritySource: 'none'
    }
  });
  const monitoringMode = createMonitoringMode({
    compare: {
      queueState: { reportPath: 'tests/results/_agent/issue/no-standing-priority.json', ready: true, status: 'queue-empty', detail: 'queue-empty' },
      continuity: { reportPath: 'tests/results/_agent/handoff/continuity-summary.json', ready: true, status: 'maintained', detail: 'safe-idle' },
      pivotGate: { reportPath: 'tests/results/_agent/promotion/template-pivot-gate-report.json', ready: true, status: 'ready', detail: 'future-agent-may-pivot' },
      readyForMonitoring: true
    },
    templateMonitoring: {
      status: 'fail',
      repositories: [
        {
          role: 'canonical-template',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          monitoringStatus: 'fail',
          openIssues: { status: 'fail', count: 2 },
          branchAlignment: null,
          supportedProof: null
        },
        {
          role: 'org-consumer-fork',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: { status: 'pass', branch: 'develop', headSha: 'abc123', canonicalHeadSha: 'abc123' },
          supportedProof: { status: 'pass', runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/1', conclusion: 'success' }
        },
        {
          role: 'personal-consumer-fork',
          repository: 'svelderrainruiz/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: { status: 'pass', branch: 'develop', headSha: 'abc123', canonicalHeadSha: 'abc123' },
          supportedProof: { status: 'pass', runUrl: 'https://github.com/svelderrainruiz/LabviewGitHubCiTemplate/actions/runs/2', conclusion: 'success' }
        }
      ],
      unsupportedPaths: []
    },
    summary: {
      status: 'blocked',
      futureAgentAction: 'reopen-template-monitoring-work',
      wakeConditionCount: 1,
      triggeredWakeConditions: ['template-canonical-open-issues']
    }
  });

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'), compareSummary);
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), monitoringMode);
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'downstream-repo-graph-truth.json'), createRepoGraphTruth());

  const { report } = await runAutonomousGovernorPortfolioSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'template-work');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.summary.nextAction, 'reopen-template-monitoring-work');
  assert.equal(report.summary.ownerDecisionSource, 'template-monitoring');
  assert.equal(report.summary.templateMonitoringStatus, 'fail');
  assert.deepEqual(
    report.portfolio.repositories.find((entry) => entry.id === 'canonical-template').triggeredWakeConditions,
    ['template-canonical-open-issues']
  );
});

test('runAutonomousGovernorPortfolioSummary keeps next owner on compare while vi-history distributor dependency is blocked', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-portfolio-vi-history-blocked-'));
  const compareSummary = createCompareGovernorSummary({
    compare: {
      queueState: { status: 'queue-empty', reason: 'queue-empty', openIssueCount: 0, ready: true },
      continuity: {
        status: 'maintained',
        turnBoundary: 'safe-idle',
        supervisionState: 'idle-monitoring',
        operatorPromptRequiredToResume: false
      },
      monitoringMode: {
        status: 'active',
        futureAgentAction: 'future-agent-may-pivot',
        wakeConditionCount: 0
      },
      releaseSigningReadiness: {
        status: 'warn',
        codePathState: 'ready',
        signingCapabilityState: 'missing',
        signingAuthorityState: 'scope-missing',
        releaseConductorApplyState: 'disabled',
        publicationState: 'unobserved',
        externalBlocker: 'workflow-signing-secret-missing'
      }
    },
    wake: {
      terminalState: 'monitoring',
      currentStage: 'monitoring',
      classification: null,
      decision: null,
      monitoringStatus: 'active',
      authoritativeTier: null,
      blockedLowerTierEvidence: false,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: null,
      issueUrl: null,
      recommendedOwnerRepository: null
    },
    summary: {
      governorMode: 'monitoring-active',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'future-agent-may-pivot',
      signalQuality: 'idle-monitoring',
      queueState: 'queue-empty',
      continuityStatus: 'maintained',
      wakeTerminalState: 'monitoring',
      monitoringStatus: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      queueHandoffStatus: 'none',
      queueHandoffNextWakeCondition: null,
      queueHandoffPrUrl: null,
      queueAuthoritySource: 'none',
      releaseSigningStatus: 'warn',
      releaseSigningAuthorityState: 'scope-missing',
      releaseConductorApplyState: 'disabled',
      releaseSigningExternalBlocker: 'workflow-signing-secret-missing',
      releasePublicationState: 'unobserved'
    }
  });
  const monitoringMode = createMonitoringMode({
    compare: {
      queueState: { reportPath: 'tests/results/_agent/issue/no-standing-priority.json', ready: true, status: 'queue-empty', detail: 'queue-empty' },
      continuity: { reportPath: 'tests/results/_agent/handoff/continuity-summary.json', ready: true, status: 'maintained', detail: 'safe-idle' },
      pivotGate: { reportPath: 'tests/results/_agent/promotion/template-pivot-gate-report.json', ready: true, status: 'ready', detail: 'future-agent-may-pivot' },
      readyForMonitoring: true
    },
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0,
      triggeredWakeConditions: []
    }
  });

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'), compareSummary);
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), monitoringMode);
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'downstream-repo-graph-truth.json'), createRepoGraphTruth());

  const { report } = await runAutonomousGovernorPortfolioSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'monitoring-active');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextAction, 'complete-compare-vi-history-producer-release');
  assert.equal(report.summary.ownerDecisionSource, 'compare-vi-history-distributor-dependency');
  assert.equal(report.summary.viHistoryDistributorDependencyStatus, 'blocked');
});

test('runAutonomousGovernorPortfolioSummary flips next owner to template once vi-history distributor dependency is ready', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-portfolio-vi-history-ready-'));
  const compareSummary = createCompareGovernorSummary({
    compare: {
      queueState: { status: 'queue-empty', reason: 'queue-empty', openIssueCount: 0, ready: true },
      continuity: {
        status: 'maintained',
        turnBoundary: 'safe-idle',
        supervisionState: 'idle-monitoring',
        operatorPromptRequiredToResume: false
      },
      monitoringMode: {
        status: 'active',
        futureAgentAction: 'future-agent-may-pivot',
        wakeConditionCount: 0
      },
      releaseSigningReadiness: {
        status: 'pass',
        codePathState: 'ready',
        signingCapabilityState: 'configured',
        signingAuthorityState: 'ready',
        releaseConductorApplyState: 'enabled',
        publicationState: 'producer-native-ready',
        publishedBundleState: 'producer-native-ready',
        publishedBundleReleaseTag: 'v0.6.4-rc.1-tools.1',
        publishedBundleAuthoritativeConsumerPin: 'v0.6.4-rc.1-tools.1',
        externalBlocker: null
      }
    },
    wake: {
      terminalState: 'monitoring',
      currentStage: 'monitoring',
      classification: null,
      decision: null,
      monitoringStatus: 'active',
      authoritativeTier: null,
      blockedLowerTierEvidence: false,
      replayMatched: false,
      replayAuthorityCompatible: null,
      issueNumber: null,
      issueUrl: null,
      recommendedOwnerRepository: null
    },
    summary: {
      governorMode: 'monitoring-active',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'future-agent-may-pivot',
      signalQuality: 'idle-monitoring',
      queueState: 'queue-empty',
      continuityStatus: 'maintained',
      wakeTerminalState: 'monitoring',
      monitoringStatus: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      queueHandoffStatus: 'none',
      queueHandoffNextWakeCondition: null,
      queueHandoffPrUrl: null,
      queueAuthoritySource: 'none',
      releaseSigningStatus: 'pass',
      releaseSigningAuthorityState: 'ready',
      releaseConductorApplyState: 'enabled',
      releaseSigningExternalBlocker: null,
      releasePublicationState: 'producer-native-ready',
      releasePublishedBundleState: 'producer-native-ready',
      releasePublishedBundleReleaseTag: 'v0.6.4-rc.1-tools.1',
      releasePublishedBundleAuthoritativeConsumerPin: 'v0.6.4-rc.1-tools.1'
    }
  });
  const monitoringMode = createMonitoringMode({
    compare: {
      queueState: { reportPath: 'tests/results/_agent/issue/no-standing-priority.json', ready: true, status: 'queue-empty', detail: 'queue-empty' },
      continuity: { reportPath: 'tests/results/_agent/handoff/continuity-summary.json', ready: true, status: 'maintained', detail: 'safe-idle' },
      pivotGate: { reportPath: 'tests/results/_agent/promotion/template-pivot-gate-report.json', ready: true, status: 'ready', detail: 'future-agent-may-pivot' },
      readyForMonitoring: true
    },
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0,
      triggeredWakeConditions: []
    }
  });

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'), compareSummary);
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), monitoringMode);
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'downstream-repo-graph-truth.json'), createRepoGraphTruth());

  const { report } = await runAutonomousGovernorPortfolioSummary({ repoRoot: tmpDir });

  assert.equal(report.summary.governorMode, 'monitoring-active');
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextOwnerRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.summary.nextAction, 'future-agent-may-pivot');
  assert.equal(report.summary.ownerDecisionSource, 'compare-monitoring-mode');
  assert.equal(report.summary.viHistoryDistributorDependencyStatus, 'ready');
  assert.equal(report.summary.viHistoryDistributorDependencyPublishedBundleState, 'producer-native-ready');
  assert.equal(report.summary.viHistoryDistributorDependencyPublishedBundleReleaseTag, 'v0.6.4-rc.1-tools.1');
  assert.equal(report.summary.viHistoryDistributorDependencyAuthoritativeConsumerPin, 'v0.6.4-rc.1-tools.1');
});
