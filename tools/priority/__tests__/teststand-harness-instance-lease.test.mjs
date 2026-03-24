#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_TTL_SECONDS,
  isTestStandHarnessInstanceLeaseStale,
  leasePathForHarnessInstance,
  runTestStandHarnessInstanceLease
} from '../teststand-harness-instance-lease.mjs';

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

function createExecutionCellLease(overrides = {}) {
  const base = {
    schema: 'priority/execution-cell-lease@v1',
    generatedAt: '2026-03-24T01:00:00.000Z',
    cellId: 'exec-cell-hooke-01',
    resourceKind: 'execution-cell',
    state: 'granted',
    sequence: 2,
    heartbeatAt: '2026-03-24T01:00:00.000Z',
    host: {
      isolatedLaneGroupId:
        'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      fingerprintSha256:
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    },
    request: {
      requestId: 'request-1',
      requestedAt: '2026-03-24T00:59:00.000Z',
      agentId: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      harnessKind: 'teststand-compare-harness',
      premiumDualLaneRequested: false,
      operatorAuthorizationRef: null,
      workingRoot: 'E:/comparevi-lanes/cells/hooke-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/artifacts'
    },
    grant: {
      grantedAt: '2026-03-24T01:00:00.000Z',
      grantor: 'execution-cell-governor',
      leaseId: 'exec-lease-1',
      premiumSaganMode: false
    },
    commit: {
      committedAt: '2026-03-24T01:01:00.000Z',
      workingRoot: 'E:/comparevi-lanes/cells/hooke-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/artifacts'
    },
    release: null
  };

  return {
    ...base,
    ...overrides,
    request: {
      ...base.request,
      ...(overrides.request || {})
    },
    grant: {
      ...base.grant,
      ...(overrides.grant || {})
    },
    commit: {
      ...base.commit,
      ...(overrides.commit || {})
    },
    host: {
      ...base.host,
      ...(overrides.host || {})
    }
  };
}

test('request and grant derive a coordinator harness instance lease from a dual-plane execution cell', async () => {
  await withTempDir('teststand-harness-instance-request-grant', async (root) => {
    const executionCellLeasePath = path.join(root, 'execution-cell.json');
    const leaseRoot = path.join(root, 'harness-leases');
    await writeJson(
      executionCellLeasePath,
      createExecutionCellLease({
        cellId: 'exec-cell-sagan-01',
        request: {
          agentId: 'sagan',
          agentClass: 'sagan',
          cellClass: 'kernel-coordinator',
          suiteClass: 'dual-plane-parity',
          planeBinding: 'dual-plane-parity',
          operatorAuthorizationRef: 'premium-authorized-2026-03-24'
        },
        grant: {
          leaseId: 'exec-lease-sagan-01',
          premiumSaganMode: true
        }
      })
    );

    const requested = await runTestStandHarnessInstanceLease({
      action: 'request',
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:02:00.000Z')
    });

    assert.equal(requested.status, 'requested');
    assert.equal(requested.lease.request.role, 'coordinator');
    assert.equal(requested.lease.request.processModelClass, 'parallel-process-model');
    assert.equal(
      requested.instanceId,
      'teststand-compare-harness-exec-cell-sagan-01-coordinator'
    );
    assert.equal(requested.summary.premiumSaganMode, true);
    assert.equal(requested.summary.operatorAuthorizationRef, 'premium-authorized-2026-03-24');

    const granted = await runTestStandHarnessInstanceLease({
      action: 'grant',
      instanceId: requested.instanceId,
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:03:00.000Z')
    });

    assert.equal(granted.status, 'granted');
    assert.equal(granted.lease.grant.ttlSeconds, DEFAULT_TTL_SECONDS);
    assert.equal(granted.summary.role, 'coordinator');
    assert.equal(granted.summary.processModelClass, 'parallel-process-model');
  });
});

test('commit and release persist working roots and artifact paths for a single-plane harness instance', async () => {
  await withTempDir('teststand-harness-instance-lifecycle', async (root) => {
    const executionCellLeasePath = path.join(root, 'execution-cell.json');
    const leaseRoot = path.join(root, 'harness-leases');
    await writeJson(executionCellLeasePath, createExecutionCellLease());

    const requested = await runTestStandHarnessInstanceLease({
      action: 'request',
      executionCellLeasePath,
      instanceId: 'ts-harness-hooke-01',
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:04:00.000Z')
    });
    const granted = await runTestStandHarnessInstanceLease({
      action: 'grant',
      instanceId: requested.instanceId,
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:05:00.000Z')
    });

    const committed = await runTestStandHarnessInstanceLease({
      action: 'commit',
      instanceId: requested.instanceId,
      leaseId: granted.lease.grant.leaseId,
      workingRoot: 'E:/comparevi-lanes/cells/hooke-01/harness/work',
      artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/harness/artifacts',
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:06:00.000Z')
    });

    assert.equal(committed.status, 'committed');
    assert.equal(committed.lease.state, 'active');
    assert.equal(committed.summary.workingRoot, 'E:/comparevi-lanes/cells/hooke-01/harness/work');
    assert.equal(committed.summary.artifactRoot, 'E:/comparevi-lanes/cells/hooke-01/harness/artifacts');

    const released = await runTestStandHarnessInstanceLease({
      action: 'release',
      instanceId: requested.instanceId,
      leaseId: granted.lease.grant.leaseId,
      artifactPaths: ['tests/results/teststand-session/session-index.json'],
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:07:00.000Z')
    });

    assert.equal(released.status, 'released');
    assert.deepEqual(released.lease.release.artifactPaths, [
      'tests/results/teststand-session/session-index.json'
    ]);
  });
});

test('plane-child grants fail closed without a parent instance and plane key', async () => {
  await withTempDir('teststand-harness-instance-plane-child-denied', async (root) => {
    const executionCellLeasePath = path.join(root, 'execution-cell.json');
    const leaseRoot = path.join(root, 'harness-leases');
    await writeJson(
      executionCellLeasePath,
      createExecutionCellLease({
        request: {
          suiteClass: 'dual-plane-parity',
          planeBinding: 'dual-plane-parity'
        }
      })
    );

    const requested = await runTestStandHarnessInstanceLease({
      action: 'request',
      executionCellLeasePath,
      role: 'plane-child',
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:08:00.000Z')
    });

    const denied = await runTestStandHarnessInstanceLease({
      action: 'grant',
      instanceId: requested.instanceId,
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:09:00.000Z')
    });

    assert.equal(denied.status, 'denied');
    assert.deepEqual(denied.summary.denialReasons.sort(), [
      'plane-child-parent-required',
      'plane-child-plane-key-required'
    ]);
  });
});

test('grant denies linux or container plane bindings for the windows-only TestStand runtime', async () => {
  await withTempDir('teststand-harness-instance-windows-only', async (root) => {
    const executionCellLeasePath = path.join(root, 'execution-cell.json');
    const leaseRoot = path.join(root, 'harness-leases');
    await writeJson(
      executionCellLeasePath,
      createExecutionCellLease({
        request: {
          planeBinding: 'docker-desktop/linux-container-2026'
        }
      })
    );

    const requested = await runTestStandHarnessInstanceLease({
      action: 'request',
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:10:00.000Z')
    });

    const denied = await runTestStandHarnessInstanceLease({
      action: 'grant',
      instanceId: requested.instanceId,
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T01:11:00.000Z')
    });

    assert.equal(denied.status, 'denied');
    assert.equal(denied.summary.denialReasons.includes('teststand-windows-native-only'), true);
  });
});

test('inspect reports stale active harness-instance leases', async () => {
  await withTempDir('teststand-harness-instance-stale', async (root) => {
    const executionCellLeasePath = path.join(root, 'execution-cell.json');
    const leaseRoot = path.join(root, 'harness-leases');
    await writeJson(executionCellLeasePath, createExecutionCellLease());

    const requested = await runTestStandHarnessInstanceLease({
      action: 'request',
      executionCellLeasePath,
      instanceId: 'ts-harness-stale-01',
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:00:00.000Z')
    });
    const granted = await runTestStandHarnessInstanceLease({
      action: 'grant',
      instanceId: requested.instanceId,
      executionCellLeasePath,
      ttlSeconds: 60,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:01:00.000Z')
    });
    await runTestStandHarnessInstanceLease({
      action: 'commit',
      instanceId: requested.instanceId,
      leaseId: granted.lease.grant.leaseId,
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:02:00.000Z')
    });

    const leasePath = leasePathForHarnessInstance(requested.instanceId, leaseRoot);
    const existing = JSON.parse(await fs.readFile(leasePath, 'utf8'));
    assert.equal(
      isTestStandHarnessInstanceLeaseStale(existing, Date.parse('2026-03-24T00:03:01.000Z')),
      true
    );

    const inspected = await runTestStandHarnessInstanceLease({
      action: 'inspect',
      instanceId: requested.instanceId,
      executionCellLeasePath,
      leaseRoot,
      repoRoot: root,
      now: new Date('2026-03-24T00:03:01.000Z')
    });

    assert.equal(inspected.status, 'stale');
    assert.equal(inspected.summary.isStale, true);
  });
});
