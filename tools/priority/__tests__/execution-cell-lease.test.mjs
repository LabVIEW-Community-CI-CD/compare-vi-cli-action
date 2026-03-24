#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_TTL_SECONDS,
  isExecutionCellLeaseStale,
  leasePathForCell,
  runExecutionCellLease
} from '../execution-cell-lease.mjs';

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

test('request and grant create an execution cell lease with host fingerprint and operator rate', async () => {
  await withTempDir('execution-cell-lease-request-grant', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    const requested = await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-hooke-01',
      agentId: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'native-labview-2026-dual',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'dual-plane-parity'],
      workingRoot: 'E:/comparevi-lanes/cells/hooke-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/artifacts',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:50:00.000Z')
    });

    assert.equal(requested.status, 'requested');
    assert.equal(requested.lease.request.agentId, 'hooke');
    assert.equal(requested.lease.request.cellClass, 'worker');
    assert.equal(requested.lease.request.suiteClass, 'dual-plane-parity');
    assert.equal(requested.lease.host.isolatedLaneGroupId, createHostPlaneReport().host.osFingerprint.isolatedLaneGroupId);

    const granted = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-hooke-01',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:51:00.000Z')
    });

    assert.equal(granted.status, 'granted');
    assert.equal(granted.lease.grant.billableRateMultiplier, 1);
    assert.equal(granted.lease.grant.billableRateUsdPerHour, 250);
    assert.equal(granted.lease.grant.ttlSeconds, DEFAULT_TTL_SECONDS);
    assert.equal(granted.lease.grant.premiumSaganMode, false);
  });
});

test('commit and release stamp the harness instance and artifact paths', async () => {
  await withTempDir('execution-cell-lease-lifecycle', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-epicurus-02',
      agentId: 'epicurus',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:52:00.000Z')
    });

    const granted = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-epicurus-02',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:53:00.000Z')
    });

    const committed = await runExecutionCellLease({
      action: 'commit',
      cellId: 'exec-cell-epicurus-02',
      leaseId: granted.lease.grant.leaseId,
      harnessInstanceId: 'harness-epicurus-02',
      workingRoot: 'E:/comparevi-lanes/cells/epicurus-02/work',
      artifactRoot: 'E:/comparevi-lanes/cells/epicurus-02/artifacts',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:54:00.000Z')
    });

    assert.equal(committed.status, 'committed');
    assert.equal(committed.lease.state, 'active');
    assert.equal(committed.lease.commit.harnessInstanceId, 'harness-epicurus-02');
    assert.equal(committed.summary.linkedDockerLaneId, null);
    assert.equal(committed.summary.linkedDockerLaneLeaseId, null);

    const released = await runExecutionCellLease({
      action: 'release',
      cellId: 'exec-cell-epicurus-02',
      leaseId: granted.lease.grant.leaseId,
      artifactPaths: ['tests/results/_agent/runtime/teststand-session.json'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:55:00.000Z')
    });

    assert.equal(released.status, 'released');
    assert.equal(released.lease.release.artifactPaths[0], 'tests/results/_agent/runtime/teststand-session.json');
  });
});

test('commit binds execution cell to a linked docker-lane report with the same agent and host fingerprint', async () => {
  await withTempDir('execution-cell-lease-linked-docker', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    const dockerLaneReportPath = path.join(root, 'docker-lane-report.json');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());
    await writeJson(dockerLaneReportPath, {
      schema: 'priority/docker-lane-handshake-report@v1',
      laneId: 'docker-agent-boyle-01',
      handshake: {
        laneId: 'docker-agent-boyle-01',
        host: createHostPlaneReport().host.osFingerprint,
        request: { agentId: 'boyle' },
        grant: { leaseId: 'docker-lease-123' }
      },
      summary: {
        holder: 'boyle',
        leaseId: 'docker-lease-123',
        isolatedLaneGroupId: createHostPlaneReport().host.osFingerprint.isolatedLaneGroupId,
        fingerprintSha256: createHostPlaneReport().host.osFingerprint.fingerprintSha256
      }
    });

    await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-boyle-01',
      agentId: 'boyle',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      capabilities: ['teststand-harness'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:10:00.000Z')
    });
    const granted = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-boyle-01',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:11:00.000Z')
    });

    const committed = await runExecutionCellLease({
      action: 'commit',
      cellId: 'exec-cell-boyle-01',
      leaseId: granted.lease.grant.leaseId,
      harnessInstanceId: 'harness-boyle-01',
      dockerLaneReportPath,
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:12:00.000Z')
    });

    assert.equal(committed.status, 'committed');
    assert.equal(committed.lease.commit.dockerLaneId, 'docker-agent-boyle-01');
    assert.equal(committed.lease.commit.dockerLaneLeaseId, 'docker-lease-123');
    assert.equal(committed.summary.linkedDockerLaneId, 'docker-agent-boyle-01');
    assert.equal(committed.summary.linkedDockerLaneLeaseId, 'docker-lease-123');
  });
});

test('inspect reports staleness for abandoned active execution cells', async () => {
  await withTempDir('execution-cell-lease-stale', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-singer-03',
      agentId: 'singer',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-32',
      capabilities: ['teststand-harness'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T20:00:00.000Z')
    });
    const granted = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-singer-03',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T20:01:00.000Z')
    });
    await runExecutionCellLease({
      action: 'commit',
      cellId: 'exec-cell-singer-03',
      leaseId: granted.lease.grant.leaseId,
      harnessInstanceId: 'harness-singer-03',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T20:02:00.000Z')
    });

    const leasePath = leasePathForCell('exec-cell-singer-03', leaseRoot);
    const existing = JSON.parse(await fs.readFile(leasePath, 'utf8'));
    assert.equal(isExecutionCellLeaseStale(existing, Date.parse('2026-03-23T21:00:01.000Z')), true);

    const inspected = await runExecutionCellLease({
      action: 'inspect',
      cellId: 'exec-cell-singer-03',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T21:00:01.000Z')
    });

    assert.equal(inspected.status, 'stale');
    assert.equal(inspected.summary.isStale, true);
  });
});

test('premium dual-lane kernel cell requires Sagan authorization and applies premium labor rate', async () => {
  await withTempDir('execution-cell-lease-premium-sagan', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-sagan-kernel-01',
      agentId: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness', 'docker-lane', 'native-labview-2026-32'],
      operatorAuthorizationRef: 'operator-premium-approved-2026-03-23',
      workingRoot: 'E:/comparevi-lanes/cells/sagan-kernel-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/sagan-kernel-01/artifacts',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:56:00.000Z')
    });

    const granted = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-sagan-kernel-01',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:57:00.000Z')
    });

    assert.equal(granted.status, 'granted');
    assert.equal(granted.lease.request.cellClass, 'kernel-coordinator');
    assert.equal(granted.lease.request.premiumDualLaneRequested, true);
    assert.equal(granted.lease.grant.premiumSaganMode, true);
    assert.equal(granted.lease.grant.policyDecision, 'sagan-premium-dual-lane');
    assert.deepEqual(granted.lease.grant.grantedCapabilities.sort(), [
      'docker-lane',
      'native-labview-2026-32',
      'teststand-harness'
    ]);
    assert.equal(granted.lease.grant.billableRateMultiplier, 1.5);
    assert.equal(granted.lease.grant.billableRateUsdPerHour, 375);
    assert.equal(granted.summary.premiumSaganMode, true);
    assert.equal(granted.summary.cellClass, 'kernel-coordinator');
    assert.equal(granted.summary.operatorAuthorizationRef, 'operator-premium-approved-2026-03-23');
  });
});

test('premium dual-lane kernel cell is denied for non-Sagan worker requests', async () => {
  await withTempDir('execution-cell-lease-premium-denied', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-hooke-kernel-01',
      agentId: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['docker-lane', 'native-labview-2026-32'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:58:00.000Z')
    });

    const denied = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-hooke-kernel-01',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:59:00.000Z')
    });

    assert.equal(denied.status, 'denied');
    assert.deepEqual(denied.summary.denialReasons.sort(), [
      'operator-authorization-required',
      'premium-kernel-cell-required',
      'premium-sagan-only'
    ]);
  });
});

test('teststand execution cells fail closed for linux or container plane bindings', async () => {
  await withTempDir('execution-cell-lease-teststand-windows-only', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const leaseRoot = path.join(root, 'leases');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runExecutionCellLease({
      action: 'request',
      cellId: 'exec-cell-hooke-linux-01',
      agentId: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'docker-desktop/linux-container-2026',
      harnessKind: 'teststand-compare-harness',
      capabilities: ['teststand-harness'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:02:00.000Z')
    });

    const denied = await runExecutionCellLease({
      action: 'grant',
      cellId: 'exec-cell-hooke-linux-01',
      hostPlaneReportPath,
      operatorCostProfilePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:03:00.000Z')
    });

    assert.equal(denied.status, 'denied');
    assert.equal(denied.summary.denialReasons.includes('teststand-windows-native-only'), true);
  });
});
