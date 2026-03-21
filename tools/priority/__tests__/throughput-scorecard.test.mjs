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
  assert.match(options.concurrentLaneStatusPath, /concurrent-lane-status-receipt\.json$/);
  assert.match(options.utilizationPolicyPath, /merge-queue-utilization-target\.json$/);
  assert.match(options.hostRamBudgetPath, /host-ram-budget\.json$/);
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
  assert.deepEqual(report.summary.reasons, [
    'actionable-work-with-idle-worker-pool',
    'logical-lane-allocation-below-floor',
    'merge-queue-occupancy-below-floor'
  ]);
  assert.equal(report.summary.metrics.readyPrInventory, 2);
  assert.equal(report.summary.metrics.currentWorkerUtilizationRatio, 0);
  assert.equal(report.workerPool.liveOrchestratorLane, 'Sagan');
  assert.equal(report.logicalLaneActivation.seededLaneCount, 20);
  assert.equal(report.logicalLaneActivation.activeLaneCount, 4);
  assert.equal(report.logicalLaneActivation.catalog[0].activationState, 'active');
  assert.equal(report.logicalLaneActivation.catalog[4].activationState, 'seeded');
  assert.equal(report.summary.metrics.seededLogicalLaneCount, 20);
  assert.equal(report.summary.metrics.activeLogicalLaneCount, 4);
  assert.equal(report.summary.metrics.inactiveLogicalLaneCount, 16);
  assert.equal(report.summary.metrics.logicalLaneAllocationRatio, 0);
  assert.equal(report.summary.metrics.logicalLaneAllocationFloorRatio, 0.5);
  assert.equal(report.summary.metrics.effectiveLogicalLaneCount, 4);
  assert.equal(report.mergeQueueUtilization.status, 'warn');
  assert.equal(report.mergeQueueUtilization.observed.occupancyRatio, 0);
  assert.deepEqual(report.mergeQueueUtilization.reasons, ['merge-queue-occupancy-below-floor']);
});

test('runThroughputScorecard writes a pass report when queue pressure and worker use are aligned', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'throughput-scorecard-'));
  const runtimeStatePath = path.join(tempDir, 'delivery-agent-state.json');
  const deliveryMemoryPath = path.join(tempDir, 'delivery-memory.json');
  const queueReportPath = path.join(tempDir, 'queue-supervisor-report.json');
  const concurrentLaneStatusPath = path.join(tempDir, 'concurrent-lane-status-receipt.json');
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
    concurrentLaneStatusPath,
    JSON.stringify({
      schema: 'priority/concurrent-lane-status-receipt@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'active',
      hostedRun: {
        observationStatus: 'active'
      },
      pullRequest: {
        observationStatus: 'queued'
      },
      summary: {
        selectedBundleId: 'hosted-plus-manual-linux-docker',
        laneCount: 3,
        activeLaneCount: 2,
        completedLaneCount: 0,
        failedLaneCount: 0,
        blockedLaneCount: 0,
        plannedLaneCount: 0,
        deferredLaneCount: 1,
        manualLaneCount: 1,
        shadowLaneCount: 0,
        orchestratorDisposition: 'wait-hosted-run'
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
      concurrentLaneStatusPath,
      utilizationPolicyPath,
      outputPath,
      now: new Date('2026-03-21T03:05:00.000Z')
  });

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.workerPool.utilizationRatio, 0.5);
  assert.equal(result.report.logicalLaneAllocation.effectiveLogicalLaneCount, 4);
  assert.equal(result.report.logicalLaneActivation.seededLaneCount, 20);
  assert.equal(result.report.logicalLaneActivation.activeLaneCount, 4);
  assert.equal(result.report.logicalLaneAllocation.allocationRatio, 0.5);
  assert.equal(result.report.delivery.hostedWaitEscapeCount, 3);
  assert.equal(result.report.queue.readySetTop[0], 1511);
  assert.equal(result.report.mergeQueueUtilization.status, 'pass');
  assert.equal(result.report.concurrentLanes.status, 'active');
  assert.equal(result.report.concurrentLanes.workerDisposition, 'retain');
  assert.equal(result.report.workerPool.liveOrchestratorLane, 'Sagan');
  assert.equal(result.report.concurrentLanes.deferredLaneCount, 1);
  assert.equal(result.report.summary.metrics.concurrentLaneActiveCount, 2);
  assert.equal(result.report.summary.metrics.concurrentLaneDeferredCount, 1);
  assert.equal(result.report.summary.metrics.mergeQueueOccupancyRatio, 1);
  assert.equal(result.report.summary.metrics.mergeQueueReadyInventoryFloor, 1);
  assert.ok(fs.existsSync(outputPath));
});

test('runThroughputScorecard falls back to the legacy runtime-state artifact when the canonical delivery state is missing', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'throughput-scorecard-legacy-'));
  const runtimeStatePath = path.join(tempDir, 'runtime-state.json');
  const deliveryMemoryPath = path.join(tempDir, 'delivery-memory.json');
  const queueReportPath = path.join(tempDir, 'queue-supervisor-report.json');
  const concurrentLaneStatusPath = path.join(tempDir, 'concurrent-lane-status-receipt.json');
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
    concurrentLaneStatusPath,
    JSON.stringify({
      schema: 'priority/concurrent-lane-status-receipt@v1',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'active',
      hostedRun: {
        observationStatus: 'active'
      },
      pullRequest: {
        observationStatus: 'queued'
      },
      summary: {
        selectedBundleId: 'hosted-plus-manual-linux-docker',
        laneCount: 3,
        activeLaneCount: 2,
        completedLaneCount: 0,
        failedLaneCount: 0,
        blockedLaneCount: 0,
        plannedLaneCount: 0,
        deferredLaneCount: 1,
        manualLaneCount: 1,
        shadowLaneCount: 0,
        orchestratorDisposition: 'wait-hosted-run'
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
    runtimeStatePath: path.join(tempDir, 'delivery-agent-state.json'),
    deliveryMemoryPath,
    queueReportPath,
    concurrentLaneStatusPath,
    utilizationPolicyPath,
    outputPath,
    now: new Date('2026-03-21T03:05:00.000Z')
  });

  assert.equal(path.basename(result.inputs.runtimeState.path), 'runtime-state.json');
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.workerPool.utilizationRatio, 0.5);
  assert.equal(result.report.logicalLaneAllocation.effectiveLogicalLaneCount, 4);
  assert.ok(fs.existsSync(outputPath));
});

test('buildThroughputScorecard projects concurrent lane status without changing warning semantics', () => {
  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 2,
        availableSlotCount: 2,
        releasedLaneCount: 1,
        utilizationRatio: 0.5
      },
      activeCodingLanes: 2
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 9,
        mergedPullRequestCount: 7,
        closedPullRequestCount: 2,
        hostedWaitEscapeCount: 4,
        meanTerminalDurationMinutes: 11.5,
        viHistorySuitePullRequestCount: 2
      }
    },
    queueReport: {
      inflight: 2,
      capacity: 1,
      effectiveMaxInflight: 2,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1589 }, { number: 1590 }]
      }
    },
    concurrentLaneStatus: {
      schema: 'priority/concurrent-lane-status-receipt@v1',
      status: 'settled',
      hostedRun: {
        observationStatus: 'completed'
      },
      pullRequest: {
        observationStatus: 'queued'
      },
      summary: {
        selectedBundleId: 'hosted-plus-host-native-32-shadow',
        laneCount: 3,
        activeLaneCount: 0,
        completedLaneCount: 2,
        failedLaneCount: 0,
        blockedLaneCount: 0,
        plannedLaneCount: 0,
        deferredLaneCount: 1,
        manualLaneCount: 0,
        shadowLaneCount: 1,
        orchestratorDisposition: 'release-with-deferred-local'
      }
    },
    inputPaths: {
      concurrentLaneStatusPath: 'tests/results/_agent/runtime/concurrent-lane-status-receipt.json'
    },
    utilizationPolicy: {
      mergeQueue: {
        readyInventoryFloor: 2,
        occupancyFloorRatio: 0.5,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    },
    now: new Date('2026-03-21T03:11:00.000Z')
  });

  assert.equal(report.summary.status, 'pass');
  assert.deepEqual(report.summary.reasons, []);
  assert.equal(report.concurrentLanes.status, 'settled');
  assert.equal(report.concurrentLanes.hostedObservationStatus, 'completed');
  assert.equal(report.concurrentLanes.pullRequestObservationStatus, 'queued');
  assert.equal(report.concurrentLanes.orchestratorDisposition, 'release-with-deferred-local');
  assert.equal(report.concurrentLanes.workerDisposition, 'release');
  assert.equal(report.concurrentLanes.shadowLaneCount, 1);
  assert.equal(report.summary.metrics.concurrentLaneActiveCount, 0);
  assert.equal(report.summary.metrics.concurrentLaneDeferredCount, 1);
  assert.equal(report.logicalLaneAllocation.floorSatisfied, true);
});

test('buildThroughputScorecard surfaces idle classification coverage from the concurrent lane runtime receipt', () => {
  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 2,
        availableSlotCount: 2,
        releasedLaneCount: 1,
        utilizationRatio: 0.5
      },
      activeCodingLanes: 1
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 4,
        mergedPullRequestCount: 3,
        closedPullRequestCount: 1,
        hostedWaitEscapeCount: 2,
        meanTerminalDurationMinutes: 10.4,
        viHistorySuitePullRequestCount: 1
      }
    },
    queueReport: {
      inflight: 1,
      capacity: 2,
      effectiveMaxInflight: 2,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1511 }]
      }
    },
    concurrentLaneStatus: {
      schema: 'priority/concurrent-lane-status-receipt@v1',
      status: 'settled',
      hostedRun: {
        observationStatus: 'completed'
      },
      pullRequest: {
        observationStatus: 'not-requested'
      },
      laneStatuses: [
        {
          id: 'hosted-linux-proof',
          laneClass: 'hosted-proof',
          executionPlane: 'hosted',
          decision: 'planned',
          availability: 'available',
          runtimeStatus: 'planned',
          reasons: ['hosted-runner-independent-from-local-host'],
          metadata: {},
          idleClassification: {
            state: 'waiting-hosted',
            source: 'execution-plane',
            signals: ['planned', 'hosted']
          }
        },
        {
          id: 'manual-linux-docker',
          laneClass: 'manual-docker',
          executionPlane: 'local',
          decision: 'deferred',
          availability: 'available',
          runtimeStatus: 'deferred',
          reasons: ['docker-engine-linux-observed'],
          metadata: {},
          idleClassification: {
            state: 'waiting-merge',
            source: 'execution-plane',
            signals: ['deferred', 'local']
          }
        }
      ],
      summary: {
        selectedBundleId: 'hosted-plus-manual-linux-docker',
        laneCount: 2,
        activeLaneCount: 0,
        completedLaneCount: 0,
        failedLaneCount: 0,
        blockedLaneCount: 0,
        plannedLaneCount: 1,
        deferredLaneCount: 1,
        manualLaneCount: 1,
        shadowLaneCount: 0,
        idleClassificationCoverage: {
          managedLaneCount: 2,
          nonWorkingLaneCount: 2,
          classifiedLaneCount: 2,
          unclassifiedLaneCount: 0,
          coverageRatio: 1,
          stateCounts: {
            'waiting-hosted': 1,
            'waiting-merge': 1,
            'policy-paused': 0,
            blocked: 0,
            prewarm: 0,
            'operator-steering': 0,
            'queue-empty': 0
          }
        },
        orchestratorDisposition: 'release-complete'
      }
    },
    utilizationPolicy: {
      mergeQueue: {
        readyInventoryFloor: 1,
        occupancyFloorRatio: 0.5,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    },
    now: new Date('2026-03-21T03:12:00.000Z')
  });

  assert.equal(report.summary.metrics.idleClassificationManagedLaneCount, 2);
  assert.equal(report.summary.metrics.idleClassificationNonWorkingLaneCount, 2);
  assert.equal(report.summary.metrics.idleClassificationClassifiedLaneCount, 2);
  assert.equal(report.summary.metrics.idleClassificationCoverageRatio, 1);
  assert.equal(report.concurrentLanes.idleClassificationCoverage.coverageRatio, 1);
  assert.equal(report.concurrentLanes.idleClassificationCoverage.stateCounts['waiting-hosted'], 1);
  assert.equal(report.concurrentLanes.idleClassificationCoverage.stateCounts['waiting-merge'], 1);
});

test('buildThroughputScorecard warns when actionable lane demand leaves the four-slot worker pool underfilled', () => {
  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      workerPool: {
        targetSlotCount: 4,
        occupiedSlotCount: 1,
        availableSlotCount: 3,
        releasedLaneCount: 0,
        utilizationRatio: 0.25
      },
      activeCodingLanes: 1
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 6,
        mergedPullRequestCount: 4,
        closedPullRequestCount: 2,
        hostedWaitEscapeCount: 3,
        meanTerminalDurationMinutes: 13.4,
        viHistorySuitePullRequestCount: 1
      }
    },
    queueReport: {
      inflight: 1,
      capacity: 2,
      effectiveMaxInflight: 3,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1601 }, { number: 1602 }, { number: 1603 }]
      }
    },
    concurrentLaneStatus: {
      schema: 'priority/concurrent-lane-status-receipt@v1',
      status: 'active',
      hostedRun: {
        observationStatus: 'active'
      },
      pullRequest: {
        observationStatus: 'queued'
      },
      summary: {
        selectedBundleId: 'hosted-plus-manual-linux-docker',
        laneCount: 4,
        activeLaneCount: 1,
        completedLaneCount: 0,
        failedLaneCount: 0,
        blockedLaneCount: 0,
        plannedLaneCount: 2,
        deferredLaneCount: 0,
        manualLaneCount: 1,
        shadowLaneCount: 0,
        orchestratorDisposition: 'retain-and-expand'
      }
    },
    utilizationPolicy: {
      mergeQueue: {
        readyInventoryFloor: 2,
        occupancyFloorRatio: 0.3,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    },
    now: new Date('2026-03-21T03:12:00.000Z')
  });

  assert.equal(report.summary.status, 'warn');
  assert.ok(report.summary.reasons.includes('actionable-work-below-worker-slot-target'));
  assert.ok(report.summary.reasons.includes('logical-lane-allocation-below-floor'));
  assert.equal(report.workerPool.targetSlotCount, 4);
  assert.equal(report.workerPool.occupiedSlotCount, 1);
  assert.equal(report.concurrentLanes.plannedLaneCount, 2);
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

test('buildThroughputScorecard derives the effective logical lane cap from the host RAM budget while preserving the configured ceiling', () => {
  const report = buildThroughputScorecard({
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeState: {
      policy: {
        capitalFabric: {
          capacityMode: 'host-ram-adaptive',
          maxLogicalLaneCount: 20,
          logicalLaneAllocationFloorRatio: 0.5,
          reservedLaneCount: 1
        }
      },
      workerPool: {
        targetSlotCount: 3,
        configuredTargetSlotCount: 8,
        occupiedSlotCount: 2,
        availableSlotCount: 1,
        releasedLaneCount: 0,
        utilizationRatio: 0.6667
      },
      activeCodingLanes: 2
    },
    hostRamBudget: {
      selectedProfile: {
        id: 'windows-mirror-heavy',
        recommendedParallelism: 3
      }
    },
    deliveryMemory: {
      summary: {
        totalTerminalPullRequestCount: 4,
        mergedPullRequestCount: 3,
        closedPullRequestCount: 1,
        hostedWaitEscapeCount: 1,
        meanTerminalDurationMinutes: 10,
        viHistorySuitePullRequestCount: 1
      }
    },
    queueReport: {
      inflight: 1,
      capacity: 1,
      effectiveMaxInflight: 2,
      paused: false,
      throughputController: { mode: 'healthy' },
      governor: { mode: 'normal' },
      readiness: {
        readySet: [{ number: 1701 }, { number: 1702 }]
      }
    },
    utilizationPolicy: {
      mergeQueue: {
        readyInventoryFloor: 1,
        occupancyFloorRatio: 0.5,
        occupancyTargetRatio: 1,
        treatPausedQueueAsExempt: true
      }
    },
    now: new Date('2026-03-21T03:13:00.000Z')
  });

  assert.equal(report.logicalLaneAllocation.capacityMode, 'host-ram-adaptive');
  assert.equal(report.logicalLaneAllocation.maxLogicalLaneCount, 20);
  assert.equal(report.logicalLaneAllocation.effectiveLogicalLaneCount, 3);
  assert.equal(report.logicalLaneActivation.activeLaneCount, 3);
  assert.equal(report.logicalLaneAllocation.hostRamProfile, 'windows-mirror-heavy');
  assert.equal(report.logicalLaneAllocation.hostRamRecommendedParallelism, 3);
  assert.equal(report.logicalLaneAllocation.capacitySource, 'host-ram-budget');
  assert.equal(report.summary.metrics.effectiveLogicalLaneCount, 3);
  assert.equal(report.summary.metrics.seededLogicalLaneCount, 20);
});
