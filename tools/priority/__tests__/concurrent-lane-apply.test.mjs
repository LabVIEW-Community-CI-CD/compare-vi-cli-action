#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync } from 'node:fs';
import { applyConcurrentLanePlan, parseArgs } from '../concurrent-lane-apply.mjs';
import { buildConcurrentLanePlan } from '../concurrent-lane-plan.mjs';

function createHostPlaneReport({ native32Status = 'ready', nativeParallelLabVIEWSupported = true } = {}) {
  return {
    schema: 'labview-2026-host-plane-report@v1',
    generatedAt: '2026-03-21T00:00:00.000Z',
    host: { os: 'windows', computerName: 'builder' },
    runner: { hostIsRunner: true, runnerName: 'builder', githubActions: false },
    docker: {
      operatorLabels: ['linux-docker-fast-loop', 'windows-docker-fast-loop', 'dual-docker-fast-loop']
    },
    policy: {
      authoritativePlanes: [
        'docker-desktop/linux-container-2026',
        'docker-desktop/windows-container-2026'
      ],
      hostNativeShadowPlane: {
        plane: 'native-labview-2026-32',
        role: 'acceleration-surface',
        authoritative: false,
        executionMode: 'manual-opt-in',
        hostedCiAllowed: false,
        promotionPrerequisites: [
          'docker-desktop/linux-container-2026',
          'docker-desktop/windows-container-2026'
        ]
      }
    },
    native: {
      parallelLabVIEWSupported: nativeParallelLabVIEWSupported,
      sharedCliAcrossNativePlanes: true,
      recommendedParallelPlanes: nativeParallelLabVIEWSupported
        ? ['native-labview-2026-64', 'native-labview-2026-32']
        : [],
      planes: {
        x64: { status: 'ready' },
        x32: { status: native32Status }
      }
    },
    executionPolicy: {
      mutuallyExclusivePairs: {
        pairs: [{ left: 'docker-desktop/linux-container-2026', right: 'docker-desktop/windows-container-2026' }]
      },
      provenParallelPairs: {
        pairs: [
          { left: 'docker-desktop/windows-container-2026', right: 'native-labview-2026-64' },
          { left: 'native-labview-2026-64', right: 'native-labview-2026-32' }
        ]
      },
      candidateParallelPairs: {
        pairs: [{ left: 'native-labview-2026-64', right: 'native-labview-2026-32' }]
      }
    }
  };
}

function createHostRamBudget(recommendedParallelism = 2) {
  return {
    schema: 'priority/host-ram-budget@v1',
    selectedProfile: {
      id: 'windows-mirror-heavy',
      recommendedParallelism
    }
  };
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createTempDir() {
  return mkdtempSync(path.join(os.tmpdir(), 'concurrent-lane-apply-'));
}

function findLane(receipt, laneId) {
  const lane = receipt.selectedLanes.find((entry) => entry.id === laneId);
  assert.ok(lane, `expected lane '${laneId}' in receipt`);
  return lane;
}

test('applyConcurrentLanePlan dispatches hosted lanes and defers manual docker lanes from a saved plan', async () => {
  const tempDir = createTempDir();
  const planPath = path.join(tempDir, 'concurrent-lane-plan.json');
  const outputPath = path.join(tempDir, 'concurrent-lane-apply-receipt.json');
  writeJson(
    planPath,
    buildConcurrentLanePlan({
      hostPlaneReport: createHostPlaneReport(),
      hostRamBudget: createHostRamBudget(),
      dockerRuntimeSnapshot: {
        schema: 'docker-runtime-determinism@v1',
        observed: {
          osType: 'linux',
          context: 'desktop-linux',
          dockerHost: 'unix:///var/run/docker.sock'
        },
        result: {
          status: 'ok'
        }
      }
    })
  );

  const dispatchCalls = [];
  const reportCalls = [];
  const options = parseArgs([
    'node',
    'concurrent-lane-apply.mjs',
    '--plan',
    planPath,
    '--output',
    outputPath,
    '--ref',
    'issue/origin-1586-concurrent-lane-apply-receipt',
    '--sample-id',
    'ts-20260321-000000-abcd',
    '--history-scenario-set',
    'history-core',
    '--allow-fork'
  ]);
  const { receipt, outputPath: writtenPath, error } = await applyConcurrentLanePlan(options, {
    dispatchValidateFn: ({ argv }) => {
      dispatchCalls.push(argv);
      return {
        dispatched: true,
        repoRoot: tempDir,
        repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        remote: 'upstream',
        ref: 'issue/origin-1586-concurrent-lane-apply-receipt',
        sampleId: 'ts-20260321-000000-abcd',
        historyScenarioSet: 'history-core',
        issueNumber: 1482,
        run: {
          databaseId: 123456789,
          status: 'queued',
          conclusion: null,
          createdAt: '2026-03-21T00:00:00Z'
        }
      };
    },
    writeValidateDispatchReportFn: (result) => {
      reportCalls.push(result);
      return {
        reportPath: path.join(tempDir, 'priority-validate-dispatch-upstream-1482.json')
      };
    }
  });

  assert.equal(error, null);
  assert.equal(receipt.status, 'succeeded');
  assert.equal(receipt.plan.source, 'file');
  assert.equal(receipt.summary.selectedBundleId, 'hosted-plus-manual-linux-docker');
  assert.equal(receipt.validateDispatch.status, 'dispatched');
  assert.equal(receipt.validateDispatch.sampleIdStrategy, 'explicit');
  assert.equal(receipt.validateDispatch.reportPath, path.join(tempDir, 'priority-validate-dispatch-upstream-1482.json'));
  assert.equal(receipt.validateDispatch.allowFork, true);
  assert.equal(receipt.validateDispatch.pushMissing, false);
  assert.equal(receipt.validateDispatch.forcePushOk, false);
  assert.equal(receipt.validateDispatch.allowNonCanonicalViHistory, false);
  assert.equal(receipt.validateDispatch.allowNonCanonicalHistoryCore, false);
  assert.equal(receipt.summary.hostedDispatchCount, 2);
  assert.deepEqual(receipt.summary.manualLaneIds, ['manual-linux-docker']);
  assert.deepEqual(receipt.summary.shadowLaneIds, []);
  assert.equal(findLane(receipt, 'hosted-linux-proof').decision, 'dispatched');
  assert.equal(findLane(receipt, 'hosted-windows-proof').decision, 'dispatched');
  assert.equal(findLane(receipt, 'manual-linux-docker').decision, 'deferred');
  assert.deepEqual(dispatchCalls[0], [
    'node',
    'dispatch-validate.mjs',
    '--ref',
    'issue/origin-1586-concurrent-lane-apply-receipt',
    '--sample-id',
    'ts-20260321-000000-abcd',
    '--history-scenario-set',
    'history-core',
    '--allow-fork'
  ]);
  assert.equal(reportCalls.length, 1);
  assert.equal(writtenPath, path.resolve(outputPath));
  assert.ok(fs.existsSync(writtenPath), 'expected receipt file to be written');
});

test('applyConcurrentLanePlan recomputes the plan and records hosted dry-run with explicit shadow deferral', async () => {
  const tempDir = createTempDir();
  const hostPlaneReportPath = path.join(tempDir, 'host-plane-report.json');
  const hostRamBudgetPath = path.join(tempDir, 'host-ram-budget.json');
  const outputPath = path.join(tempDir, 'concurrent-lane-apply-receipt.json');
  writeJson(hostPlaneReportPath, createHostPlaneReport());
  writeJson(hostRamBudgetPath, createHostRamBudget(1));

  let dispatchCalled = false;
  const options = parseArgs([
    'node',
    'concurrent-lane-apply.mjs',
    '--recompute-plan',
    '--output',
    outputPath,
    '--host-plane-report',
    hostPlaneReportPath,
    '--host-ram-budget',
    hostRamBudgetPath,
    '--shadow-mode',
    'prefer',
    '--dry-run'
  ]);
  const { receipt, error } = await applyConcurrentLanePlan(options, {
    dispatchValidateFn: () => {
      dispatchCalled = true;
      throw new Error('dispatch should not run during dry-run');
    }
  });

  assert.equal(error, null);
  assert.equal(dispatchCalled, false);
  assert.equal(receipt.status, 'succeeded');
  assert.equal(receipt.plan.source, 'recomputed');
  assert.equal(receipt.summary.selectedBundleId, 'hosted-plus-host-native-32-shadow');
  assert.equal(receipt.validateDispatch.status, 'dry-run');
  assert.equal(receipt.validateDispatch.sampleIdStrategy, 'auto');
  assert.equal(receipt.validateDispatch.allowFork, false);
  assert.equal(receipt.validateDispatch.pushMissing, false);
  assert.equal(findLane(receipt, 'hosted-linux-proof').decision, 'planned-dispatch');
  assert.equal(findLane(receipt, 'hosted-windows-proof').decision, 'planned-dispatch');
  assert.equal(findLane(receipt, 'host-native-32-shadow').decision, 'deferred');
  assert.deepEqual(receipt.summary.manualLaneIds, []);
  assert.deepEqual(receipt.summary.shadowLaneIds, ['host-native-32-shadow']);
  assert.ok(fs.existsSync(path.resolve(outputPath)), 'expected receipt file to be written');
});

test('applyConcurrentLanePlan writes a failed receipt when hosted dispatch fails', async () => {
  const tempDir = createTempDir();
  const planPath = path.join(tempDir, 'concurrent-lane-plan.json');
  const outputPath = path.join(tempDir, 'concurrent-lane-apply-receipt.json');
  writeJson(
    planPath,
    buildConcurrentLanePlan({
      hostPlaneReport: createHostPlaneReport(),
      hostRamBudget: createHostRamBudget(),
      dockerRuntimeSnapshot: {
        schema: 'docker-runtime-determinism@v1',
        observed: {
          osType: 'linux',
          context: 'desktop-linux',
          dockerHost: 'unix:///var/run/docker.sock'
        },
        result: {
          status: 'ok'
        }
      }
    })
  );

  const options = parseArgs([
    'node',
    'concurrent-lane-apply.mjs',
    '--plan',
    planPath,
    '--output',
    outputPath
  ]);
  const { receipt, outputPath: writtenPath, error } = await applyConcurrentLanePlan(options, {
    dispatchValidateFn: () => {
      throw new Error('gh workflow dispatch failed');
    }
  });

  assert.match(error?.message ?? '', /gh workflow dispatch failed/);
  assert.equal(receipt.status, 'failed');
  assert.equal(receipt.validateDispatch.status, 'failed');
  assert.equal(receipt.validateDispatch.sampleIdStrategy, 'auto');
  assert.match(receipt.validateDispatch.error ?? '', /gh workflow dispatch failed/);
  assert.equal(findLane(receipt, 'hosted-linux-proof').decision, 'blocked');
  assert.equal(findLane(receipt, 'hosted-windows-proof').decision, 'blocked');
  assert.equal(findLane(receipt, 'manual-linux-docker').decision, 'deferred');
  assert.ok(fs.existsSync(writtenPath), 'expected failed receipt file to be written');
});

test('applyConcurrentLanePlan falls back to recomputing the default plan when no planner artifact exists yet', async () => {
  const originalCwd = process.cwd();
  const tempDir = createTempDir();
  try {
    process.chdir(tempDir);
    writeJson(
      path.join(tempDir, 'tests', 'results', '_agent', 'host-planes', 'labview-2026-host-plane-report.json'),
      createHostPlaneReport()
    );
    writeJson(
      path.join(tempDir, 'tests', 'results', '_agent', 'runtime', 'host-ram-budget.json'),
      createHostRamBudget(1)
    );

    const { receipt, error } = await applyConcurrentLanePlan(
      parseArgs(['node', 'concurrent-lane-apply.mjs', '--dry-run', '--shadow-mode', 'prefer']),
      {
        dispatchValidateFn: () => {
          throw new Error('dispatch should not run during dry-run');
        }
      }
    );

    assert.equal(error, null);
    assert.equal(receipt.plan.source, 'recomputed');
    assert.equal(receipt.summary.selectedBundleId, 'hosted-plus-host-native-32-shadow');
    assert.equal(receipt.validateDispatch.status, 'dry-run');
    assert.ok(
      fs.existsSync(path.join(tempDir, 'tests', 'results', '_agent', 'runtime', 'concurrent-lane-apply-receipt.json')),
      'expected default receipt path to be written'
    );
  } finally {
    process.chdir(originalCwd);
  }
});
