#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs, runThroughputScorecard, buildThroughputScorecard } from '../throughput-scorecard.mjs';

test('throughput-scorecard parseArgs exposes deterministic defaults', () => {
  const options = parseArgs(['node', 'throughput-scorecard.mjs']);
  assert.match(options.runtimeStatePath, /delivery-agent-state\.json$/);
  assert.match(options.deliveryMemoryPath, /delivery-memory\.json$/);
  assert.match(options.queueReportPath, /queue-supervisor-report\.json$/);
  assert.match(options.utilizationPolicyPath, /merge-queue-utilization-target\.json$/);
  assert.match(options.outputPath, /throughput-scorecard\.json$/);
});

test('buildThroughputScorecard warns when actionable work exists while the worker pool is idle', () => {
  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 0,
        availableSlotCount: 4,
        releasedLaneCount: 1,
        utilizationRatio: 0
      },
      activeCodingLanes: 0
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 3,
        mergedPullRequestCount: 2,
        closedPullRequestCount: 1,
        hostedWaitEscapeCount: 2,
        meanTerminalDurationMinutes: 17.5,
        viHistorySuitePullRequestCount: 1
      }
    },
    queueReport: {
      inflight: 0,
      capacity: 2,
      effectiveMaxInflight: 2,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1511 }, { number: 1512 }]
      }
    },
    utilizationPolicy: {
      mergeQueue: {
        readyInventoryFloor: 2,
        occupancyFloorRatio: 0.5,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    },
    now: new Date('2026-03-21T03:00:00.000Z')
  });

  assert.equal(report.summary.status, 'warn');
  assert.deepEqual(report.summary.reasons, ['actionable-work-with-idle-worker-pool', 'merge-queue-occupancy-below-floor']);
  assert.equal(report.summary.metrics.readyPrInventory, 2);
  assert.equal(report.summary.metrics.currentWorkerUtilizationRatio, 0);
  assert.equal(report.mergeQueueUtilization.status, 'warn');
  assert.equal(report.mergeQueueUtilization.observed.occupancyRatio, 0);
  assert.deepEqual(report.mergeQueueUtilization.reasons, ['merge-queue-occupancy-below-floor']);
});

test('runThroughputScorecard writes a pass report when queue pressure and worker use are aligned', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'throughput-scorecard-'));
  const runtimeStatePath = path.join(tempDir, 'delivery-agent-state.json');
  const deliveryMemoryPath = path.join(tempDir, 'delivery-memory.json');
  const queueReportPath = path.join(tempDir, 'queue-supervisor-report.json');
  const utilizationPolicyPath = path.join(tempDir, 'merge-queue-utilization-target.json');
  const outputPath = path.join(tempDir, 'throughput-scorecard.json');

  fs.writeFileSync(
    runtimeStatePath,
    JSON.stringify({
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 2,
        availableSlotCount: 2,
        releasedLaneCount: 1,
        utilizationRatio: 0.5
      },
      activeCodingLanes: 2
    }),
    'utf8'
  );
  fs.writeFileSync(
    deliveryMemoryPath,
    JSON.stringify({
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      summary: {
        totalTerminalPullRequestCount: 5,
        mergedPullRequestCount: 4,
        closedPullRequestCount: 1,
        hostedWaitEscapeCount: 3,
        meanTerminalDurationMinutes: 14.2,
        viHistorySuitePullRequestCount: 2
      }
    }),
    'utf8'
  );
  fs.writeFileSync(
    queueReportPath,
    JSON.stringify({
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      inflight: 2,
      capacity: 0,
      effectiveMaxInflight: 2,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1511 }]
      }
    }),
    'utf8'
  );
  fs.writeFileSync(
    utilizationPolicyPath,
    JSON.stringify({
      schema: 'priority/merge-queue-utilization-target@v1',
      mergeQueue: {
        readyInventoryFloor: 1,
        occupancyFloorRatio: 0.5,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    }),
    'utf8'
  );

  const result = runThroughputScorecard({
    runtimeStatePath,
    deliveryMemoryPath,
    queueReportPath,
    utilizationPolicyPath,
    outputPath,
    now: new Date('2026-03-21T03:05:00.000Z')
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.workerPool.utilizationRatio, 0.5);
  assert.equal(result.report.delivery.hostedWaitEscapeCount, 3);
  assert.equal(result.report.queue.readySetTop[0], 1511);
  assert.equal(result.report.mergeQueueUtilization.status, 'pass');
  assert.equal(result.report.summary.metrics.mergeQueueOccupancyRatio, 1);
  assert.equal(result.report.summary.metrics.mergeQueueReadyInventoryFloor, 1);
  assert.ok(fs.existsSync(outputPath));
});

test('buildThroughputScorecard warns when merge-queue ready inventory drops below the defined floor', () => {
  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 3,
        availableSlotCount: 1,
        releasedLaneCount: 0,
        utilizationRatio: 0.75
      },
      activeCodingLanes: 3
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 8,
        mergedPullRequestCount: 7,
        closedPullRequestCount: 1,
        hostedWaitEscapeCount: 2,
        meanTerminalDurationMinutes: 12,
        viHistorySuitePullRequestCount: 1
      }
    },
    queueReport: {
      inflight: 2,
      capacity: 1,
      effectiveMaxInflight: 3,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1491 }]
      }
    },
    utilizationPolicy: {
      mergeQueue: {
        readyInventoryFloor: 2,
        occupancyFloorRatio: 0.5,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    },
    now: new Date('2026-03-21T03:06:00.000Z')
  });

  assert.equal(report.mergeQueueUtilization.status, 'warn');
  assert.deepEqual(report.mergeQueueUtilization.reasons, ['merge-queue-ready-inventory-below-floor']);
  assert.ok(report.summary.reasons.includes('merge-queue-ready-inventory-below-floor'));
  assert.equal(report.summary.metrics.mergeQueueReadyInventoryFloor, 2);
});
