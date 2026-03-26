import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildCrossRepoLaneBrokerDecision } from '../cross-repo-lane-broker.mjs';

const repoRoot = path.resolve(process.cwd());

test('cross-repo lane broker decision matches the checked-in schema', () => {
  const report = buildCrossRepoLaneBrokerDecision({
    repoRoot: '/tmp/repo',
    currentRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    governorPortfolioHandoff: {
      status: 'owner-match',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'future-agent-may-pivot',
      ownerDecisionSource: 'compare-monitoring-mode',
      governorMode: 'monitoring-active',
      viHistoryDistributorDependencyStatus: 'ready',
      viHistoryDistributorDependencyTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      viHistoryDistributorDependencyExternalBlocker: null
    },
    marketplaceSnapshot: {
      schema: 'priority/lane-marketplace-snapshot@v1',
      generatedAt: '2026-03-26T02:22:00.000Z',
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
    },
    marketplaceSnapshotPath: 'tests/results/_agent/marketplace/lane-marketplace-snapshot.json',
    policy: {
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
          }
        ]
      }
    },
    policyPath: 'tools/priority/delivery-agent.policy.json'
  });

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs/schemas/cross-repo-lane-broker-decision-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  if (!valid) {
    const errors = (validate.errors || [])
      .map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`)
      .join('\n');
    assert.fail(`Cross-repo lane broker decision failed schema validation:\n${errors}`);
  }
});
