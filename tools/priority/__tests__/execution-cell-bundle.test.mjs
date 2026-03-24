#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { main, runExecutionCellBundle } from '../execution-cell-bundle.mjs';

async function withTempDir(prefix, fn) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), `${prefix}-`));
  try {
    return await fn(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function writeJson(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createHostPlaneReport() {
  return {
    schema: 'labview-2026-host-plane-report@v1',
    host: {
      computerName: 'canonical-builder',
      osFingerprint: {
        isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        platform: 'windows',
        canonical: {
          version: '10.0.26200',
          buildNumber: '26200',
          ubr: 8037
        }
      }
    }
  };
}

function createOperatorCostProfile() {
  return {
    schema: 'priority/operator-cost-profile@v1',
    currency: 'USD',
    defaultOperatorId: 'sergio',
    operators: [
      {
        id: 'sergio',
        laborRateUsdPerHour: 250,
        active: true
      }
    ]
  };
}

test('execution-cell bundle grants coordinated worker cell and docker lane at ordinary rate', async () => {
  await withTempDir('execution-cell-bundle-worker', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'execution-cell-leases');
    const handshakeRoot = path.join(root, 'docker-lane-handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    const requested = await runExecutionCellBundle({
      action: 'request',
      cellId: 'exec-cell-hooke-02',
      laneId: 'docker-agent-hooke-02',
      agentId: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      workingRoot: 'E:/comparevi-lanes/cells/hooke-02/work',
      artifactRoot: 'E:/comparevi-lanes/cells/hooke-02/artifacts',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:00:00.000Z')
    });

    assert.equal(requested.status, 'requested');
    assert.equal(requested.summary.dockerRequested, true);

    const granted = await runExecutionCellBundle({
      action: 'grant',
      cellId: 'exec-cell-hooke-02',
      laneId: 'docker-agent-hooke-02',
      agentId: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:01:00.000Z')
    });

    assert.equal(granted.status, 'granted');
    assert.equal(granted.executionCell.status, 'granted');
    assert.equal(granted.dockerLane.status, 'granted');
    assert.equal(granted.summary.effectiveBillableRateUsdPerHour, 250);
    assert.equal(granted.summary.premiumSaganRequested, false);
    assert.equal(granted.summary.premiumSaganMode, false);
    assert.equal(granted.summary.operatorAuthorizationRequired, false);
    assert.equal(granted.summary.operatorAuthorizationPromptRequired, false);
    assert.equal(granted.summary.estimatedFollowupAuthorizationsNeeded, 0);
    assert.equal(granted.summary.treasuryDecisionCode, null);
    assert.equal(granted.summary.windowsNativeTestStand, true);
    assert.equal(granted.summary.reciprocalLinkReady, false);
  });
});

test('execution-cell bundle infers premium Sagan dual-lane mode for dual-plane parity with docker', async () => {
  await withTempDir('execution-cell-bundle-sagan-premium', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'execution-cell-leases');
    const handshakeRoot = path.join(root, 'docker-lane-handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellBundle({
      action: 'request',
      cellId: 'exec-cell-sagan-kernel-02',
      laneId: 'docker-agent-sagan-kernel-02',
      agentId: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
      workingRoot: 'E:/comparevi-lanes/cells/sagan-kernel-02/work',
      artifactRoot: 'E:/comparevi-lanes/cells/sagan-kernel-02/artifacts',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:02:00.000Z')
    });

    const granted = await runExecutionCellBundle({
      action: 'grant',
      cellId: 'exec-cell-sagan-kernel-02',
      laneId: 'docker-agent-sagan-kernel-02',
      agentId: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:03:00.000Z')
    });

    assert.equal(granted.status, 'granted');
    assert.equal(granted.executionCell.status, 'granted');
    assert.equal(granted.dockerLane.status, 'granted');
    assert.equal(granted.summary.premiumSaganRequested, true);
    assert.equal(granted.summary.premiumSaganMode, true);
    assert.equal(granted.summary.operatorAuthorizationRequired, true);
    assert.equal(granted.summary.operatorAuthorizationPromptRequired, true);
    assert.equal(granted.summary.estimatedFollowupAuthorizationsNeeded, 1);
    assert.equal(granted.summary.effectiveBillableRateUsdPerHour, 375);
    assert.equal(granted.summary.reciprocalLinkReady, false);
    assert.deepEqual(
      granted.summary.capabilities.sort(),
      ['docker-lane', 'native-labview-2026-32', 'teststand-harness'].sort()
    );
  });
});

test('execution-cell bundle fails closed when treasury denies premium Sagan mode', async () => {
  await withTempDir('execution-cell-bundle-premium-treasury-denied', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    const denied = await runExecutionCellBundle({
      action: 'request',
      cellId: 'exec-cell-sagan-kernel-03',
      laneId: 'docker-agent-sagan-kernel-03',
      agentId: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
      repoRoot: root,
      runTreasuryOperationGuardFn: () => ({
        outputPath: path.join(root, 'tests', 'results', '_agent', 'cost', 'treasury-control-plane.json'),
        decision: {
          allowed: false,
          code: 'treasury-operation-denied',
          reason: 'Treasury denied premium-sagan: budget-tight.',
          authorization: {
            requiresOperatorAuthorization: true,
            requiresExplicitOperatorPrompt: true,
            estimatedFollowupAuthorizationsNeeded: 2
          }
        }
      })
    });

    assert.equal(denied.status, 'denied');
    assert.equal(denied.executionCell, null);
    assert.equal(denied.dockerLane, null);
    assert.equal(denied.summary.premiumSaganRequested, true);
    assert.equal(denied.summary.premiumSaganMode, false);
    assert.equal(denied.summary.operatorAuthorizationRequired, true);
    assert.equal(denied.summary.operatorAuthorizationPromptRequired, true);
    assert.equal(denied.summary.estimatedFollowupAuthorizationsNeeded, 2);
    assert.equal(denied.summary.treasuryDecisionCode, 'treasury-operation-denied');
    assert.match(denied.summary.treasuryControlPlanePath, /treasury-control-plane\.json$/);
    assert.match(denied.summary.denialReasons.join('\n'), /treasury-operation-denied/);
  });
});

test('execution-cell bundle surfaces an explicit operator authorization prompt when premium mode lacks authorization', async () => {
  await withTempDir('execution-cell-bundle-premium-auth-required', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    const denied = await runExecutionCellBundle({
      action: 'request',
      cellId: 'exec-cell-sagan-kernel-04',
      laneId: 'docker-agent-sagan-kernel-04',
      agentId: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      repoRoot: root,
      runTreasuryOperationGuardFn: () => ({
        outputPath: path.join(root, 'tests', 'results', '_agent', 'cost', 'treasury-control-plane.json'),
        decision: {
          allowed: true,
          code: 'treasury-operation-allowed',
          reason: 'budget-healthy',
          authorization: {
            requiresOperatorAuthorization: true,
            requiresExplicitOperatorPrompt: true,
            estimatedFollowupAuthorizationsNeeded: 1
          }
        }
      })
    });

    assert.equal(denied.status, 'denied');
    assert.equal(denied.summary.premiumSaganRequested, true);
    assert.equal(denied.summary.operatorAuthorizationRequired, true);
    assert.equal(denied.summary.operatorAuthorizationPromptRequired, true);
    assert.equal(denied.summary.estimatedFollowupAuthorizationsNeeded, 1);
    assert.match(denied.summary.denialReasons.join('\n'), /operator-authorization-required/);
    assert.match(denied.summary.observations.join('\n'), /premium-operator-prompt-required/);
  });
});

test('execution-cell bundle denies linux-bound TestStand cells and rolls back requested docker lanes', async () => {
  await withTempDir('execution-cell-bundle-linux-teststand', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'execution-cell-leases');
    const handshakeRoot = path.join(root, 'docker-lane-handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellBundle({
      action: 'request',
      cellId: 'exec-cell-mill-linux-01',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'docker-desktop/linux-container-2026',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:04:00.000Z')
    });

    const denied = await runExecutionCellBundle({
      action: 'grant',
      cellId: 'exec-cell-mill-linux-01',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'docker-desktop/linux-container-2026',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:05:00.000Z')
    });

    assert.equal(denied.status, 'denied');
    assert.match(denied.summary.denialReasons.join('\n'), /teststand-windows-native-only/);
    assert.equal(denied.rollbacks.dockerLane.status, 'released');
  });
});

test('execution-cell bundle commits and releases both leases together', async () => {
  await withTempDir('execution-cell-bundle-commit-release', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'execution-cell-leases');
    const handshakeRoot = path.join(root, 'docker-lane-handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellBundle({
      action: 'request',
      cellId: 'exec-cell-epicurus-03',
      laneId: 'docker-agent-epicurus-03',
      agentId: 'epicurus',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:06:00.000Z')
    });
    await runExecutionCellBundle({
      action: 'grant',
      cellId: 'exec-cell-epicurus-03',
      laneId: 'docker-agent-epicurus-03',
      agentId: 'epicurus',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:07:00.000Z')
    });

    const committed = await runExecutionCellBundle({
      action: 'commit',
      cellId: 'exec-cell-epicurus-03',
      laneId: 'docker-agent-epicurus-03',
      agentId: 'epicurus',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      harnessInstanceId: 'harness-epicurus-03',
      workingRoot: 'E:/comparevi-lanes/cells/epicurus-03/work',
      artifactRoot: 'E:/comparevi-lanes/cells/epicurus-03/artifacts',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:08:00.000Z')
    });

    assert.equal(committed.status, 'committed');
    assert.equal(committed.executionCell.status, 'committed');
    assert.equal(committed.dockerLane.status, 'committed');
    assert.equal(committed.summary.executionCellLeaseId, committed.executionCell.summary.leaseId);
    assert.equal(committed.summary.dockerLaneLeaseId, committed.dockerLane.summary.leaseId);
    assert.equal(committed.summary.linkedExecutionCellId, 'exec-cell-epicurus-03');
    assert.equal(committed.summary.linkedDockerLaneId, 'docker-agent-epicurus-03');
    assert.equal(committed.executionCell.summary.linkedDockerLaneId, 'docker-agent-epicurus-03');
    assert.equal(
      committed.executionCell.summary.linkedDockerLaneLeaseId,
      committed.dockerLane.summary.leaseId
    );
    assert.equal(committed.dockerLane.summary.linkedExecutionCellId, 'exec-cell-epicurus-03');
    assert.equal(
      committed.dockerLane.summary.linkedExecutionCellLeaseId,
      committed.executionCell.summary.leaseId
    );
    assert.equal(committed.summary.reciprocalLinkReady, true);

    const released = await runExecutionCellBundle({
      action: 'release',
      cellId: 'exec-cell-epicurus-03',
      laneId: 'docker-agent-epicurus-03',
      agentId: 'epicurus',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-24T02:09:00.000Z')
    });

    assert.equal(released.status, 'released');
    assert.equal(released.executionCell.status, 'released');
    assert.equal(released.dockerLane.status, 'released');
  });
});

test('execution-cell bundle CLI main writes a request receipt', async () => {
  await withTempDir('execution-cell-bundle-cli', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const outputPath = path.join(root, 'execution-cell-bundle-cli.json');
    const leaseRoot = path.join(root, 'execution-cell-leases');
    const handshakeRoot = path.join(root, 'docker-lane-handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    const exitCode = await main([
      'node',
      path.join(root, 'execution-cell-bundle.mjs'),
      '--action',
      'request',
      '--cell-id',
      'exec-cell-boyle-04',
      '--lane-id',
      'docker-agent-boyle-04',
      '--agent-id',
      'boyle',
      '--agent-class',
      'subagent',
      '--cell-class',
      'worker',
      '--suite-class',
      'single-compare',
      '--plane-binding',
      'native-labview-2026-64',
      '--capability',
      'teststand-harness',
      '--capability',
      'docker-lane',
      '--host-plane-report',
      hostPlaneReportPath,
      '--operator-cost-profile',
      operatorCostProfilePath,
      '--lease-root',
      leaseRoot,
      '--handshake-root',
      handshakeRoot,
      '--output',
      outputPath
    ]);

    assert.equal(exitCode, 0);
    const receipt = JSON.parse(await fs.readFile(outputPath, 'utf8'));
    assert.equal(receipt.status, 'requested');
    assert.equal(receipt.cellId, 'exec-cell-boyle-04');
    assert.equal(receipt.laneId, 'docker-agent-boyle-04');
  });
});
