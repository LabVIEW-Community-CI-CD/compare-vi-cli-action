import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runSaganContextConcentrator } from '../sagan-context-concentrator.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createGovernorSummary() {
  return {
    schema: 'priority/autonomous-governor-summary-report@v1',
    generatedAt: '2026-03-23T22:30:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      queueEmptyReportPath: 'tests/results/_agent/issue/no-standing-priority.json',
      continuitySummaryPath: 'tests/results/_agent/handoff/continuity-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      wakeLifecyclePath: 'tests/results/_agent/issue/wake-lifecycle.json',
      wakeInvestmentAccountingPath: 'tests/results/_agent/capital/wake-investment-accounting.json',
      deliveryRuntimeStatePath: 'tests/results/_agent/runtime/delivery-agent-state.json',
      releaseSigningReadinessPath: 'tests/results/_agent/release/release-signing-readiness.json'
    },
    compare: {},
    wake: {},
    funding: {},
    summary: {
      governorMode: 'compare-governance-work',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'publish-producer-native-vi-history-bundle',
      queueState: 'active',
      monitoringStatus: 'active',
      workerPoolAuthoritySource: 'throughput-scorecard',
      workerPoolTargetSlotCount: 4,
      workerPoolOccupiedSlotCount: 4,
      workerPoolAvailableSlotCount: 0,
      workerPoolReleasedLaneCount: 1,
      workerPoolUtilizationRatio: 1,
      workerPoolReleasedCapitalAvailable: true,
      workerPoolIdleWorkerCapacityAvailable: false,
      workerPoolUnderfilled: false,
      workerPoolThroughputStatus: 'pressure',
      workerPoolThroughputPressureReasons: ['actionable-work-with-idle-worker-pool'],
      workerPoolQueueThroughputMode: 'surge',
      releaseSigningStatus: 'warn',
      releaseSigningExternalBlocker: 'tag-signature-unverified',
      releasePublicationState: 'tag-created-not-published',
      releasePublishedBundleState: 'producer-native-incomplete',
      releasePublishedBundleReleaseTag: 'v0.6.3-tools.14'
    }
  };
}

function createGovernorPortfolioSummary(overrides = {}) {
  const summaryOverrides = overrides.summary || {};
  return {
    schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
    generatedAt: '2026-03-23T22:31:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      compareGovernorSummaryPath: 'tests/results/_agent/handoff/autonomous-governor-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      repoGraphTruthPath: 'tests/results/_agent/handoff/downstream-repo-graph-truth.json'
    },
    compare: {},
    portfolio: {
      repositoryCount: 4,
      repositories: [],
      dependencies: [],
      unsupportedPaths: []
    },
    summary: {
      status: 'active',
      governorMode: 'compare-governance-work',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'publish-producer-native-vi-history-bundle',
      brokerSelectedIssueNumber: null,
      brokerSelectedIssueUrl: null,
      brokerSelectedIssueTitle: null,
      brokerProviderId: null,
      brokerSlotId: null,
      brokerSelectionSource: null,
      ownerDecisionSource: 'compare-governor-summary',
      templateMonitoringStatus: 'pass',
      supportedProofStatus: 'pass',
      repoGraphStatus: 'pass',
      workerPoolAuthoritySource: 'queue-supervisor',
      workerPoolTargetSlotCount: 4,
      workerPoolOccupiedSlotCount: 3,
      workerPoolAvailableSlotCount: 1,
      workerPoolReleasedLaneCount: 1,
      workerPoolUtilizationRatio: 0.75,
      workerPoolReleasedCapitalAvailable: true,
      workerPoolIdleWorkerCapacityAvailable: true,
      workerPoolUnderfilled: true,
      workerPoolThroughputStatus: null,
      workerPoolThroughputPressureReasons: [],
      workerPoolQueueThroughputMode: 'stabilize',
      queueHandoffStatus: 'none',
      queueHandoffNextWakeCondition: null,
      queueHandoffPrUrl: null,
      queueAuthoritySource: 'none',
      viHistoryDistributorDependencyStatus: 'blocked',
      viHistoryDistributorDependencyTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      viHistoryDistributorDependencyExternalBlocker: 'producer-native-incomplete',
      viHistoryDistributorDependencyPublicationState: 'tag-created-not-published',
      viHistoryDistributorDependencyPublishedBundleState: 'producer-native-incomplete',
      viHistoryDistributorDependencyPublishedBundleReleaseTag: 'v0.6.3-tools.14',
      viHistoryDistributorDependencyAuthoritativeConsumerPin: null,
      viHistoryDistributorDependencySigningAuthorityState: 'configured',
      ...summaryOverrides
    }
  };
}

function createMonitoringMode() {
  return {
    schema: 'agent-handoff/monitoring-mode-v1',
    generatedAt: '2026-03-23T22:32:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    summary: {
      status: 'active',
      futureAgentAction: 'remain-in-monitoring',
      wakeConditionCount: 0
    }
  };
}

function createEpisode(agentName, status, generatedAt, extra = {}) {
  return {
    schema: 'priority/subagent-episode-report@v1',
    generatedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      sourcePath: `tmp/${agentName}.json`
    },
    episodeId: `${agentName}-${generatedAt.replace(/[:.]/g, '-')}`,
    agent: {
      id: `${agentName.toLowerCase()}-id`,
      name: agentName,
      role: 'explorer',
      model: 'gpt-5.4-mini'
    },
    task: {
      summary: extra.taskSummary || `Task from ${agentName}`,
      class: 'exploration',
      issueNumber: 1909,
      issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
    },
    execution: {
      status: 'completed',
      lane: '1909-sagan-context-concentrator',
      branch: 'issue/upstream-1909-sagan-context-concentrator',
      executionPlane: extra.executionPlane || 'windows-host',
      dockerLaneId: extra.dockerLaneId || null,
      hostCapabilityLeaseId: null
    },
    summary: {
      status,
      outcome: extra.outcome || null,
      blocker: extra.blocker || null,
      nextAction: extra.nextAction || null,
      detail: extra.detail || null
    },
    evidence: {
      filesTouched: extra.filesTouched || [],
      receipts: extra.receipts || [],
      commands: [],
      notes: []
    },
    cost: {
      observedDurationSeconds: extra.durationSeconds || 60,
      tokenUsd: extra.tokenUsd || 0.05,
      operatorLaborUsd: extra.operatorLaborUsd || 4.166667,
      blendedLowerBoundUsd: extra.blendedLowerBoundUsd || 4.216667
    }
  };
}

test('runSaganContextConcentrator builds hot and warm memory from episodes and governor state', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'sagan-context-concentrator-'));
  writeJson(path.join(repoRoot, '.agent_priority_cache.json'), {
    number: 1877,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    title: '[release]: publish CompareVI.Tools bundle with native vi-history capability contract',
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1877',
    state: 'OPEN'
  });
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'),
    createGovernorSummary()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-portfolio-summary.json'),
    createGovernorPortfolioSummary()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'),
    createMonitoringMode()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'memory', 'subagent-episodes', 'euler.json'),
    createEpisode('Euler', 'reported', '2026-03-23T22:20:00Z', {
      blocker: 'handoff-seam-open',
      nextAction: 'patch Print-AgentHandoff',
      dockerLaneId: 'docker-euler-001',
      tokenUsd: 0.08,
      operatorLaborUsd: 6.25,
      blendedLowerBoundUsd: 6.33
    })
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'memory', 'subagent-episodes', 'euclid.json'),
    createEpisode('Euclid', 'reported', '2026-03-23T22:25:00Z', {
      nextAction: 'reuse governor schema style',
      tokenUsd: 0.05,
      operatorLaborUsd: 4.166667,
      blendedLowerBoundUsd: 4.216667
    })
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'memory', 'subagent-episodes', 'hooke.json'),
    createEpisode('Hooke', 'completed', '2026-03-23T22:10:00Z', {
      outcome: 'template-blocker-confirmed',
      nextAction: 'hold template #18 until compare publication',
      executionPlane: 'docker-lane',
      dockerLaneId: 'docker-hooke-001'
    })
  );

  const { report, outputPath } = await runSaganContextConcentrator(
    {
      repoRoot
    },
    {
      now: new Date('2026-03-23T22:35:00Z')
    }
  );

  assert.equal(report.schema, 'priority/sagan-context-concentrator-report@v1');
  assert.equal(report.focus.activeIssue.number, 1877);
  assert.equal(report.summary.currentOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.nextAction, 'publish-producer-native-vi-history-bundle');
  assert.equal(report.focus.workerPoolAuthoritySource, 'queue-supervisor');
  assert.equal(report.focus.workerPoolAvailableSlotCount, 1);
  assert.equal(report.summary.hotWorkingSetCount, report.memory.hotWorkingSet.length);
  assert.equal(report.episodes.validCount, 3);
  assert.ok(report.episodes.byAgent.some((entry) => entry.agentName === 'Euler'));
  assert.equal(report.cost.tokenUsd, 0.18);
  assert.equal(report.cost.blendedLowerBoundUsd, 14.763334);
  assert.ok(report.memory.hotWorkingSet.some((entry) => entry.kind === 'dependency'));
  assert.ok(report.memory.hotWorkingSet.some((entry) => entry.id === 'worker-pool-capital'));
  assert.ok(report.memory.hotWorkingSet.some((entry) => entry.agentName === 'Euler'));
  assert.ok(report.memory.warmMemory.some((entry) => entry.agentName === 'Hooke'));
  assert.ok(fs.existsSync(outputPath));
});

test('runSaganContextConcentrator tolerates missing optional episode directory', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'sagan-context-concentrator-empty-'));
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'),
    createGovernorSummary()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-portfolio-summary.json'),
    createGovernorPortfolioSummary()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'),
    createMonitoringMode()
  );

  const { report } = await runSaganContextConcentrator(
    {
      repoRoot
    },
    {
      now: new Date('2026-03-23T22:40:00Z')
    }
  );

  assert.equal(report.episodes.totalCount, 0);
  assert.equal(report.summary.concentrationStatus, 'pass');
  assert.equal(report.summary.hotWorkingSetCount >= 2, true);
});

test('runSaganContextConcentrator surfaces broker-selected issue attribution in focus and summary', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'sagan-context-concentrator-broker-'));
  writeJson(path.join(repoRoot, '.agent_priority_cache.json'), {
    number: 1986,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    title: '[ci]: surface broker-selected issue and slot attribution in portfolio handoff',
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1986',
    state: 'OPEN'
  });
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'),
    createGovernorSummary()
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-portfolio-summary.json'),
    createGovernorPortfolioSummary({
      summary: {
        currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        nextAction: 'resume-template-consumer-rail',
        brokerSelectedIssueNumber: 52,
        brokerSelectedIssueUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52',
        brokerSelectedIssueTitle: '[comparevi]: template consumer rail',
        brokerProviderId: 'local-codex',
        brokerSlotId: 'slot-template-1',
        brokerSelectionSource: 'released-waiting-state-marketplace'
      }
    })
  );
  writeJson(
    path.join(repoRoot, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'),
    createMonitoringMode()
  );

  const { report } = await runSaganContextConcentrator(
    {
      repoRoot
    },
    {
      now: new Date('2026-03-23T22:50:00Z')
    }
  );

  assert.equal(report.focus.brokerSelectedIssueNumber, 52);
  assert.equal(
    report.focus.brokerSelectedIssueUrl,
    'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52'
  );
  assert.equal(report.focus.brokerSelectedIssueTitle, '[comparevi]: template consumer rail');
  assert.equal(report.focus.brokerProviderId, 'local-codex');
  assert.equal(report.focus.brokerSlotId, 'slot-template-1');
  assert.equal(report.focus.brokerSelectionSource, 'released-waiting-state-marketplace');
  assert.equal(report.summary.brokerSelectedIssueNumber, 52);
  assert.equal(report.summary.brokerProviderId, 'local-codex');
  assert.equal(report.summary.brokerSlotId, 'slot-template-1');
  assert.equal(report.summary.brokerSelectionSource, 'released-waiting-state-marketplace');
});
