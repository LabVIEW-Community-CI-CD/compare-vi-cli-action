#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { parseArgs, runAgentSpendGapSlo } from '../agent-spend-gap-slo.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function buildTurn({
  issueNumber = 1650,
  laneId = 'issue/origin-1650-agent-spend-gap-slo',
  turnId,
  observedAt,
  agentRole = 'live',
  providerId = 'codex-cli',
  effectiveModel = 'gpt-5.4',
  effectiveReasoningEffort = 'medium',
  amountUsd = 0.02,
  exactness = 'estimated'
}) {
  return {
    sourcePath: `tests/results/_agent/cost/${turnId}.json`,
    generatedAt: observedAt,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issueNumber,
    laneId,
    laneBranch: laneId,
    sessionId: `session-${issueNumber}`,
    turnId,
    workerSlotId: 'worker-slot-1',
    agentRole,
    providerId,
    providerKind: 'local-codex',
    providerRuntime: 'codex-cli',
    executionPlane: 'wsl2',
    requestedModel: effectiveModel,
    effectiveModel,
    requestedReasoningEffort: effectiveReasoningEffort,
    effectiveReasoningEffort,
    usageUnitKind: 'turn',
    usageUnitCount: 1,
    inputTokens: 1000,
    cachedInputTokens: 0,
    outputTokens: 100,
    totalTokens: 1100,
    exactness,
    amountUsd,
    amountSource: 'rate-card-estimate',
    rateCardId: 'openai-public-2026-03-01',
    rateCardSource: 'https://openai.com/api/pricing',
    rateCardRetrievedAt: '2026-03-21T18:00:00.000Z',
    pricingBasis: 'per-1k-tokens',
    provenance: {
      sourceSchema: 'priority/agent-cost-turn@v1',
      sourceReceiptPath: `tests/results/_agent/cost/${turnId}.json`,
      sourceReportPath: null,
      usageObservedAt: observedAt
    }
  };
}

function buildThroughput({
  reasons = [],
  readyPrInventory = 0,
  currentWorkerUtilizationRatio = 0,
  concurrentLaneActiveCount = 0,
  concurrentLaneDeferredCount = 0,
  hostedWaitEscapeCount = 0
}) {
  return {
    schema: 'priority/throughput-scorecard@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: reasons.length > 0 ? 'warn' : 'pass',
      reasons,
      metrics: {
        currentWorkerUtilizationRatio,
        readyPrInventory,
        mergeQueueInflight: 0,
        mergeQueueCapacity: 2,
        mergeQueueOccupancyRatio: 0,
        mergeQueueReadyInventoryFloor: 1,
        concurrentLaneActiveCount,
        concurrentLaneDeferredCount,
        hostedWaitEscapeCount,
        meanTerminalDurationMinutes: 12
      }
    }
  };
}

test('agent-spend-gap-slo parseArgs exposes deterministic defaults', () => {
  const options = parseArgs(['node', 'agent-spend-gap-slo.mjs']);
  assert.match(options.costRollupPath, /agent-cost-rollup\.json$/);
  assert.match(options.throughputScorecardPath, /throughput-scorecard\.json$/);
  assert.match(options.outputPath, /agent-spend-gap-slo\.json$/);
  assert.equal(options.gapThresholdMinutes, 30);
});

test('runAgentSpendGapSlo classifies actionable idle gaps as optimization signals and preserves reasoning effort evidence', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-spend-gap-slo-opt-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputPath = path.join(tempDir, 'throughput-scorecard.json');
  const outputPath = path.join(tempDir, 'agent-spend-gap-slo.json');

  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turns: [
      buildTurn({
        turnId: 'turn-1',
        observedAt: '2026-03-21T00:00:00.000Z',
        effectiveReasoningEffort: 'xhigh'
      }),
      buildTurn({
        turnId: 'turn-2',
        observedAt: '2026-03-21T00:40:00.000Z',
        effectiveReasoningEffort: 'high'
      })
    ]
  });
  writeJson(
    throughputPath,
    buildThroughput({
      reasons: ['actionable-work-with-idle-worker-pool'],
      readyPrInventory: 2,
      currentWorkerUtilizationRatio: 0
    })
  );

  const result = runAgentSpendGapSlo({
    costRollupPath,
    throughputScorecardPath: throughputPath,
    outputPath,
    gapThresholdMinutes: 30,
    now: new Date('2026-03-21T01:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.metrics.totalGapCount, 1);
  assert.equal(result.report.summary.metrics.optimizationSignalGapCount, 1);
  assert.equal(result.report.gaps[0].classification, 'optimization-signal');
  assert.equal(result.report.gaps[0].previousTurn.effectiveReasoningEffort, 'xhigh');
  assert.equal(result.report.gaps[0].nextTurn.effectiveReasoningEffort, 'high');
  assert.equal(fs.existsSync(outputPath), true);
});

test('runAgentSpendGapSlo classifies quiet windows without raising an optimization warning', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-spend-gap-slo-quiet-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputPath = path.join(tempDir, 'throughput-scorecard.json');

  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turns: [
      buildTurn({
        turnId: 'turn-1',
        observedAt: '2026-03-21T02:00:00.000Z'
      }),
      buildTurn({
        turnId: 'turn-2',
        observedAt: '2026-03-21T02:45:00.000Z'
      })
    ]
  });
  writeJson(throughputPath, buildThroughput({}));

  const result = runAgentSpendGapSlo({
    costRollupPath,
    throughputScorecardPath: throughputPath,
    gapThresholdMinutes: 30,
    now: new Date('2026-03-21T03:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.metrics.quietWindowGapCount, 1);
  assert.equal(result.report.gaps[0].classification, 'accepted-quiet-window');
});

test('runAgentSpendGapSlo classifies tracked follow-up work when a gap bridges tracked issues and concurrent lane demand remains active', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-spend-gap-slo-track-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputPath = path.join(tempDir, 'throughput-scorecard.json');

  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turns: [
      buildTurn({
        issueNumber: 1650,
        laneId: 'issue/origin-1650-agent-spend-gap-slo',
        turnId: 'turn-1',
        observedAt: '2026-03-21T04:00:00.000Z'
      }),
      buildTurn({
        issueNumber: 1651,
        laneId: 'issue/origin-1651-other-lane',
        turnId: 'turn-2',
        observedAt: '2026-03-21T04:50:00.000Z'
      })
    ]
  });
  writeJson(
    throughputPath,
    buildThroughput({
      currentWorkerUtilizationRatio: 0.5,
      concurrentLaneActiveCount: 1,
      concurrentLaneDeferredCount: 1
    })
  );

  const result = runAgentSpendGapSlo({
    costRollupPath,
    throughputScorecardPath: throughputPath,
    gapThresholdMinutes: 30,
    now: new Date('2026-03-21T05:00:00.000Z')
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.metrics.trackedGapCount, 1);
  assert.equal(result.report.gaps[0].classification, 'tracked-followup');
  assert.equal(result.report.gaps[0].trackingIssueNumber, 1651);
});

test('runAgentSpendGapSlo does not emit false-positive gaps when comparable turn timestamps are missing', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-spend-gap-slo-missing-'));
  const costRollupPath = path.join(tempDir, 'agent-cost-rollup.json');
  const throughputPath = path.join(tempDir, 'throughput-scorecard.json');

  writeJson(costRollupPath, {
    schema: 'priority/agent-cost-rollup@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    turns: [
      {
        ...buildTurn({
          turnId: 'turn-1',
          observedAt: '2026-03-21T06:00:00.000Z'
        }),
        generatedAt: null,
        provenance: {
          sourceSchema: 'priority/agent-cost-turn@v1',
          sourceReceiptPath: 'tests/results/_agent/cost/turn-1.json',
          sourceReportPath: null,
          usageObservedAt: null
        }
      },
      buildTurn({
        turnId: 'turn-2',
        observedAt: '2026-03-21T07:00:00.000Z'
      })
    ]
  });
  writeJson(throughputPath, buildThroughput({ readyPrInventory: 3, currentWorkerUtilizationRatio: 0 }));

  const result = runAgentSpendGapSlo({
    costRollupPath,
    throughputScorecardPath: throughputPath,
    gapThresholdMinutes: 30,
    now: new Date('2026-03-21T07:05:00.000Z')
  });

  assert.equal(result.report.summary.metrics.totalSpendTurns, 2);
  assert.equal(result.report.summary.metrics.totalGapCount, 0);
  assert.deepEqual(result.report.gaps, []);
  assert.ok(result.report.summary.reasons.includes('no-spend-gaps-observed'));
});
