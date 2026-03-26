import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { buildCrossRepoLaneBrokerDecision, runCrossRepoLaneBroker } from '../cross-repo-lane-broker.mjs';

function createPolicy() {
  return {
    schema: 'priority/delivery-agent-policy@v1',
    implementationRemote: 'origin',
    maxActiveCodingLanes: 4,
    workerPool: {
      targetSlotCount: 4,
      providers: [
        {
          id: 'local-codex',
          kind: 'local',
          enabled: true,
          slotCount: 2,
          executionPlane: 'local',
          assignmentMode: 'interactive-coding',
          dispatchSurface: 'codex-cli',
          completionMode: 'synchronous',
          requiresLocalCheckout: true
        },
        {
          id: 'hosted-github-workflow',
          kind: 'hosted',
          enabled: true,
          slotCount: 2,
          executionPlane: 'hosted',
          assignmentMode: 'async-validation',
          dispatchSurface: 'github-actions',
          completionMode: 'waiting',
          requiresLocalCheckout: false
        }
      ]
    }
  };
}

function createMarketplaceSnapshot() {
  return {
    schema: 'priority/lane-marketplace-snapshot@v1',
    generatedAt: '2026-03-26T02:20:00.000Z',
    registryPath: 'tools/priority/lane-marketplace.json',
    summary: {
      repositoryCount: 3,
      eligibleLaneCount: 2,
      queueEmptyCount: 1,
      labelMissingCount: 0,
      errorCount: 0,
      topEligibleLane: {
        repository: 'LabVIEW-Community-CI-CD/comparevi-history',
        issueNumber: 301,
        authorityTier: 'shared-platform',
        promotionRail: 'shared-platform'
      }
    },
    entries: [
      {
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        eligible: false,
        reason: 'queue-empty',
        standing: null,
        authorityTier: 'upstream-integration',
        laneClass: 'upstream',
        promotionRail: 'integration',
        standingLabels: ['standing-priority'],
        ranking: { order: 3 }
      },
      {
        repository: 'LabVIEW-Community-CI-CD/comparevi-history',
        eligible: true,
        reason: 'standing-ready',
        standing: {
          number: 301,
          url: 'https://github.com/LabVIEW-Community-CI-CD/comparevi-history/issues/301',
          title: '[ci]: history proving lane'
        },
        authorityTier: 'shared-platform',
        laneClass: 'consumer-platform',
        promotionRail: 'shared-platform',
        standingLabels: ['standing-priority'],
        ranking: { order: 1 }
      },
      {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        eligible: true,
        reason: 'standing-ready',
        standing: {
          number: 52,
          url: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/52',
          title: '[comparevi]: template consumer rail'
        },
        authorityTier: 'consumer-proving',
        laneClass: 'consumer-template',
        promotionRail: 'consumer-proving',
        standingLabels: ['standing-priority'],
        ranking: { order: 2 }
      }
    ]
  };
}

test('cross-repo lane broker prefers the governor-suggested repository when it is eligible', () => {
  const report = buildCrossRepoLaneBrokerDecision({
    repoRoot: '/tmp/repo',
    currentRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    governorPortfolioHandoff: {
      status: 'owner-match',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'future-agent-may-pivot',
      ownerDecisionSource: 'compare-monitoring-mode',
      governorMode: 'monitoring-active'
    },
    marketplaceSnapshot: createMarketplaceSnapshot(),
    marketplaceSnapshotPath: 'tests/results/_agent/marketplace/lane-marketplace-snapshot.json',
    policy: createPolicy(),
    policyPath: 'tools/priority/delivery-agent.policy.json'
  });

  assert.equal(report.decision.status, 'ready');
  assert.equal(report.decision.selectionSource, 'governor-preferred');
  assert.equal(report.decision.selectedRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(report.decision.selectedIssueNumber, 52);
  assert.equal(report.decision.selectedProviderId, 'local-codex');
  assert.equal(report.decision.selectedSlotId, 'worker-slot-1');
  assert.equal(report.marketplace.recommendation.repository, 'LabVIEW-Community-CI-CD/comparevi-history');
});

test('cross-repo lane broker falls back to the top-ranked external marketplace candidate when governor preference is absent', () => {
  const report = buildCrossRepoLaneBrokerDecision({
    repoRoot: '/tmp/repo',
    currentRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    governorPortfolioHandoff: {
      status: 'external-owner',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
      nextAction: 'continue-fork-review',
      ownerDecisionSource: 'fork-owner',
      governorMode: 'fork-review'
    },
    marketplaceSnapshot: createMarketplaceSnapshot(),
    marketplaceSnapshotPath: 'tests/results/_agent/marketplace/lane-marketplace-snapshot.json',
    policy: createPolicy(),
    policyPath: 'tools/priority/delivery-agent.policy.json'
  });

  assert.equal(report.decision.status, 'ready');
  assert.equal(report.decision.selectionSource, 'marketplace-top-ranked');
  assert.equal(report.decision.selectedRepository, 'LabVIEW-Community-CI-CD/comparevi-history');
  assert.equal(report.decision.selectedIssueNumber, 301);
});

test('cross-repo lane broker fails closed when governor keeps work in the current repository', () => {
  const report = buildCrossRepoLaneBrokerDecision({
    repoRoot: '/tmp/repo',
    currentRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    governorPortfolioHandoff: {
      status: 'owner-match',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'continue-compare-governance-work',
      ownerDecisionSource: 'compare-governor-summary',
      governorMode: 'compare-governance-work'
    },
    marketplaceSnapshot: createMarketplaceSnapshot(),
    marketplaceSnapshotPath: 'tests/results/_agent/marketplace/lane-marketplace-snapshot.json',
    policy: createPolicy(),
    policyPath: 'tools/priority/delivery-agent.policy.json'
  });

  assert.equal(report.decision.status, 'same-repository');
  assert.equal(report.decision.selectedRepository, null);
});

test('cross-repo lane broker writes a machine-readable receipt', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'cross-repo-lane-broker-'));
  const result = await runCrossRepoLaneBroker({
    repoRoot: tempRoot,
    currentRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    governorPortfolioHandoff: {
      status: 'owner-match',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'future-agent-may-pivot',
      ownerDecisionSource: 'compare-monitoring-mode',
      governorMode: 'monitoring-active'
    },
    marketplaceSnapshot: createMarketplaceSnapshot(),
    policy: createPolicy()
  });

  const written = JSON.parse(fs.readFileSync(result.outputPath, 'utf8'));
  assert.equal(written.schema, 'priority/cross-repo-lane-broker-decision@v1');
  assert.equal(written.decision.status, 'ready');
  assert.equal(written.decision.selectedRepository, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
});
