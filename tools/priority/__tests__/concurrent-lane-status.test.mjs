#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync } from 'node:fs';
import { classifyIdleLaneState, observeConcurrentLaneStatus, parseArgs } from '../concurrent-lane-status.mjs';

function createTempDir() {
  return mkdtempSync(path.join(os.tmpdir(), 'concurrent-lane-status-'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('classifyIdleLaneState maps non-working lane signals onto the managed idle fabric states', () => {
  assert.equal(
    classifyIdleLaneState({ runtimeStatus: 'planned', executionPlane: 'hosted', laneClass: 'hosted-proof' })?.state,
    'waiting-hosted'
  );
  assert.equal(
    classifyIdleLaneState({ runtimeStatus: 'deferred', executionPlane: 'local', laneClass: 'manual-docker' })?.state,
    'waiting-merge'
  );
  assert.equal(
    classifyIdleLaneState({ runtimeStatus: 'blocked', executionPlane: 'local', laneClass: 'manual-docker' })?.state,
    'blocked'
  );
  assert.equal(
    classifyIdleLaneState({
      runtimeStatus: 'deferred',
      executionPlane: 'local',
      laneClass: 'manual-docker',
      availability: 'disabled',
      reasons: ['policy-paused']
    })?.state,
    'policy-paused'
  );
  assert.equal(
    classifyIdleLaneState({
      runtimeStatus: 'deferred',
      executionPlane: 'local-shadow',
      laneClass: 'shadow-validation'
    })?.state,
    'prewarm'
  );
  assert.equal(
    classifyIdleLaneState({
      runtimeStatus: 'deferred',
      executionPlane: 'local',
      laneClass: 'manual-docker',
      metadata: { operatorSteering: true }
    })?.state,
    'operator-steering'
  );
  assert.equal(
    classifyIdleLaneState({
      runtimeStatus: 'deferred',
      executionPlane: 'local',
      laneClass: 'manual-docker',
      reasons: ['queue-empty']
    })?.state,
    'queue-empty'
  );
  assert.equal(classifyIdleLaneState({ runtimeStatus: 'active', executionPlane: 'hosted', laneClass: 'hosted-proof' }), null);
});

function createApplyReceipt(overrides = {}) {
  return {
    schema: 'priority/concurrent-lane-apply-receipt@v1',
    generatedAt: '2026-03-21T00:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'succeeded',
    plan: {
      source: 'file',
      path: 'tests/results/_agent/runtime/concurrent-lane-plan.json',
      schema: 'priority/concurrent-lane-plan@v1',
      recommendedBundleId: 'hosted-plus-manual-linux-docker',
      selectedBundle: {
        id: 'hosted-plus-manual-linux-docker',
        classification: 'recommended',
        laneIds: ['hosted-linux-proof', 'hosted-windows-proof', 'manual-linux-docker'],
        reasons: ['test']
      }
    },
    validateDispatch: {
      status: 'dispatched',
      command: ['node', 'tools/npm/run-script.mjs', 'priority:validate', '--', '--ref', 'issue/origin-1588-concurrent-lane-status-helper'],
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      remote: 'upstream',
      ref: 'issue/origin-1588-concurrent-lane-status-helper',
      sampleId: 'ts-20260321-000000-abcd',
      historyScenarioSet: 'history-core',
      reportPath: 'tests/results/_agent/issue/priority-validate-dispatch-upstream-1482.json',
      runDatabaseId: 234567890,
      error: null
    },
    selectedLanes: [
      {
        id: 'hosted-linux-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'available',
        decision: 'dispatched',
        reasons: ['hosted-runner-independent-from-local-host'],
        metadata: {}
      },
      {
        id: 'hosted-windows-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'available',
        decision: 'dispatched',
        reasons: ['hosted-runner-independent-from-local-host'],
        metadata: {}
      },
      {
        id: 'manual-linux-docker',
        laneClass: 'manual-docker',
        executionPlane: 'local',
        resourceGroup: 'docker-desktop-linux',
        availability: 'available',
        decision: 'deferred',
        reasons: ['docker-engine-linux-observed'],
        metadata: {}
      }
    ],
    observations: ['test'],
    summary: {
      selectedBundleId: 'hosted-plus-manual-linux-docker',
      selectedLaneCount: 3,
      hostedDispatchCount: 2,
      deferredLaneCount: 1,
      hostedLaneIds: ['hosted-linux-proof', 'hosted-windows-proof'],
      deferredLaneIds: ['manual-linux-docker'],
      manualLaneIds: ['manual-linux-docker'],
      shadowLaneIds: []
    },
    ...overrides
  };
}

test('observeConcurrentLaneStatus projects active hosted lanes and queued PR merge state', async () => {
  const tempDir = createTempDir();
  const applyReceiptPath = path.join(tempDir, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-apply-receipt.json');
  const outputPath = path.join(tempDir, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-status-receipt.json');
  writeJson(applyReceiptPath, createApplyReceipt());

  const ghJsonCalls = [];
  const ghGraphqlCalls = [];
  const { receipt, outputPath: writtenPath } = await observeConcurrentLaneStatus(
    parseArgs(['node', 'concurrent-lane-status.mjs', '--apply-receipt', applyReceiptPath, '--output', outputPath]),
    {
      ensureGhCliFn: () => {},
      getRepoRootFn: () => tempDir,
      resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
      runGhJsonFn: (_repoRoot, args) => {
        ghJsonCalls.push(args);
        if (args[0] === 'api') {
          return {
            id: 234567890,
            html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/234567890',
            status: 'in_progress',
            conclusion: null,
            name: 'Validate',
            display_title: 'Validate',
            head_branch: 'issue/origin-1588-concurrent-lane-status-helper',
            head_sha: 'abc123',
            created_at: '2026-03-21T00:00:00Z',
            updated_at: '2026-03-21T00:05:00Z'
          };
        }
        if (args[0] === 'pr') {
          return {
            number: 1589,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1589',
            state: 'OPEN',
            isDraft: false,
            headRefName: 'issue/origin-1588-concurrent-lane-status-helper',
            mergeStateStatus: 'CLEAN',
            statusCheckRollup: [
              {
                __typename: 'CheckRun',
                status: 'COMPLETED',
                conclusion: 'SUCCESS'
              },
              {
                __typename: 'CheckRun',
                status: 'IN_PROGRESS',
                conclusion: ''
              }
            ]
          };
        }
        throw new Error(`Unexpected gh args: ${args.join(' ')}`);
      },
      runGhGraphqlFn: (_repoRoot, _query, variables) => {
        ghGraphqlCalls.push(variables);
        return {
          data: {
            repository: {
              pullRequest: {
                mergeQueueEntry: {
                  position: 2,
                  estimatedTimeToMerge: 420,
                  enqueuedAt: '2026-03-21T01:00:00Z'
                }
              }
            }
          }
        };
      }
    }
  );

  assert.equal(receipt.status, 'active');
  assert.equal(receipt.plan.path, 'tests/results/_agent/runtime/concurrent-lane-plan.json');
  assert.equal(receipt.plan.schema, 'priority/concurrent-lane-plan@v1');
  assert.equal(receipt.plan.source, 'file');
  assert.equal(receipt.plan.recommendedBundleId, 'hosted-plus-manual-linux-docker');
  assert.equal(receipt.plan.selectedBundleId, 'hosted-plus-manual-linux-docker');
  assert.equal(receipt.hostedRun.observationStatus, 'active');
  assert.equal(receipt.pullRequest.observationStatus, 'queued');
  assert.equal(receipt.summary.orchestratorDisposition, 'wait-hosted-run');
  assert.equal(receipt.summary.activeLaneCount, 2);
  assert.equal(receipt.summary.deferredLaneCount, 1);
  assert.equal(receipt.laneStatuses[0].idleClassification, null);
  assert.equal(receipt.laneStatuses[2].idleClassification?.state, 'waiting-merge');
  assert.equal(receipt.summary.idleClassificationCoverage.managedLaneCount, 3);
  assert.equal(receipt.summary.idleClassificationCoverage.nonWorkingLaneCount, 1);
  assert.equal(receipt.summary.idleClassificationCoverage.classifiedLaneCount, 1);
  assert.equal(receipt.summary.idleClassificationCoverage.coverageRatio, 1);
  assert.equal(receipt.summary.idleClassificationCoverage.stateCounts['waiting-hosted'], 0);
  assert.equal(receipt.summary.idleClassificationCoverage.stateCounts['waiting-merge'], 1);
  assert.equal(receipt.pullRequest.mergeQueue.position, 2);
  assert.equal(receipt.pullRequest.checksSummary.pending, 1);
  assert.ok(receipt.laneStatuses.every((entry) => entry.id !== 'manual-linux-docker' || entry.runtimeStatus === 'deferred'));
  assert.ok(fs.existsSync(writtenPath), 'expected status receipt to be written');
  assert.equal(ghJsonCalls.length, 2);
  assert.equal(ghGraphqlCalls.length, 1);
});

test('observeConcurrentLaneStatus settles completed hosted runs and keeps deferred shadow lanes explicit', async () => {
  const tempDir = createTempDir();
  const applyReceiptPath = path.join(tempDir, 'apply.json');
  writeJson(
    applyReceiptPath,
    createApplyReceipt({
      plan: {
        source: 'file',
        path: 'tests/results/_agent/runtime/concurrent-lane-plan.json',
        schema: 'priority/concurrent-lane-plan@v1',
        recommendedBundleId: 'hosted-plus-host-native-32-shadow',
        selectedBundle: {
          id: 'hosted-plus-host-native-32-shadow',
          classification: 'recommended',
          laneIds: ['hosted-linux-proof', 'hosted-windows-proof', 'host-native-32-shadow'],
          reasons: ['test']
        }
      },
      selectedLanes: [
        {
          id: 'hosted-linux-proof',
          laneClass: 'hosted-proof',
          executionPlane: 'hosted',
          resourceGroup: 'hosted-github',
          availability: 'available',
          decision: 'dispatched',
          reasons: ['hosted-runner-independent-from-local-host'],
          metadata: {}
        },
        {
          id: 'hosted-windows-proof',
          laneClass: 'hosted-proof',
          executionPlane: 'hosted',
          resourceGroup: 'hosted-github',
          availability: 'available',
          decision: 'dispatched',
          reasons: ['hosted-runner-independent-from-local-host'],
          metadata: {}
        },
        {
          id: 'host-native-32-shadow',
          laneClass: 'shadow-validation',
          executionPlane: 'local-shadow',
          resourceGroup: 'native-labview-2026-32',
          availability: 'available',
          decision: 'deferred',
          reasons: ['shadow-acceleration-only'],
          metadata: {
            authoritative: false
          }
        }
      ],
      summary: {
        selectedBundleId: 'hosted-plus-host-native-32-shadow',
        selectedLaneCount: 3,
        hostedDispatchCount: 2,
        deferredLaneCount: 1,
        hostedLaneIds: ['hosted-linux-proof', 'hosted-windows-proof'],
        deferredLaneIds: ['host-native-32-shadow'],
        manualLaneIds: [],
        shadowLaneIds: ['host-native-32-shadow']
      },
      validateDispatch: {
        status: 'dispatched',
        command: ['node', 'tools/npm/run-script.mjs', 'priority:validate', '--'],
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        remote: 'upstream',
        ref: null,
        sampleId: 'ts-20260321-000000-abcd',
        historyScenarioSet: 'smoke',
        reportPath: 'tests/results/_agent/issue/report.json',
        runDatabaseId: 345678901,
        error: null
      }
    })
  );

  const { receipt } = await observeConcurrentLaneStatus(
    parseArgs(['node', 'concurrent-lane-status.mjs', '--apply-receipt', applyReceiptPath]),
    {
      ensureGhCliFn: () => {},
      getRepoRootFn: () => tempDir,
      resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
      runGhJsonFn: (_repoRoot, args) => {
        if (args[0] === 'api') {
          return {
            id: 345678901,
            html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/345678901',
            status: 'completed',
            conclusion: 'success',
            name: 'Validate',
            display_title: 'Validate',
            head_branch: 'issue/origin-1588-concurrent-lane-status-helper',
            head_sha: 'def456',
            created_at: '2026-03-21T00:00:00Z',
            updated_at: '2026-03-21T00:10:00Z'
          };
        }
        throw new Error(`Unexpected gh args: ${args.join(' ')}`);
      },
      runGhGraphqlFn: () => {
        throw new Error('PR queue observation should not run without a selector');
      }
    }
  );

  assert.equal(receipt.status, 'settled');
  assert.equal(receipt.plan.path, 'tests/results/_agent/runtime/concurrent-lane-plan.json');
  assert.equal(receipt.plan.schema, 'priority/concurrent-lane-plan@v1');
  assert.equal(receipt.plan.source, 'file');
  assert.equal(receipt.plan.recommendedBundleId, 'hosted-plus-host-native-32-shadow');
  assert.equal(receipt.plan.selectedBundleId, 'hosted-plus-host-native-32-shadow');
  assert.equal(receipt.hostedRun.observationStatus, 'completed');
  assert.equal(receipt.pullRequest.observationStatus, 'not-requested');
  assert.equal(receipt.summary.shadowLaneCount, 1);
  assert.equal(receipt.summary.orchestratorDisposition, 'release-with-deferred-local');
  assert.equal(
    receipt.laneStatuses.find((entry) => entry.id === 'host-native-32-shadow')?.runtimeStatus,
    'deferred'
  );
});

test('observeConcurrentLaneStatus fails closed when hosted workflow observation fails', async () => {
  const tempDir = createTempDir();
  const applyReceiptPath = path.join(tempDir, 'apply.json');
  writeJson(applyReceiptPath, createApplyReceipt());

  const { receipt } = await observeConcurrentLaneStatus(
    parseArgs(['node', 'concurrent-lane-status.mjs', '--apply-receipt', applyReceiptPath]),
    {
      ensureGhCliFn: () => {},
      getRepoRootFn: () => tempDir,
      resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
      runGhJsonFn: (_repoRoot, args) => {
        if (args[0] === 'api') {
          throw new Error('GitHub API rate limited');
        }
        return null;
      },
      runGhGraphqlFn: () => ({
        data: {
          repository: {
            pullRequest: {
              mergeQueueEntry: null
            }
          }
        }
      })
    }
  );

  assert.equal(receipt.status, 'failed');
  assert.equal(receipt.hostedRun.observationStatus, 'failed');
  assert.equal(receipt.summary.orchestratorDisposition, 'hold-investigate');
  assert.match(receipt.observationErrors[0] ?? '', /rate limited/i);
  assert.equal(receipt.laneStatuses.find((entry) => entry.id === 'hosted-linux-proof')?.runtimeStatus, 'failed');
});
