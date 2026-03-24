#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_TTL_SECONDS,
  DOCKER_LANE_CAPABILITY,
  NATIVE_LV32_CAPABILITY,
  PREMIUM_RATE_MULTIPLIER,
  handshakePathForLane,
  isHandshakeStale,
  runDockerLaneHandshake
} from '../docker-lane-handshake.mjs';

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

test('request creates a docker-lane handshake with host isolated-lane fingerprint context', async () => {
  await withTempDir('docker-lane-handshake-request', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    const report = await runDockerLaneHandshake({
      action: 'request',
      laneId: 'docker-agent-epicurus-linux-01',
      agentId: 'epicurus',
      agentClass: 'subagent',
      capabilities: [DOCKER_LANE_CAPABILITY],
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot: path.join(root, 'handshakes'),
      repoRoot: root,
      now: new Date('2026-03-23T23:50:00.000Z')
    });

    assert.equal(report.status, 'requested');
    assert.equal(report.handshake.state, 'requested');
    assert.equal(report.handshake.host.isolatedLaneGroupId, createHostPlaneReport().host.osFingerprint.isolatedLaneGroupId);
    assert.equal(report.handshake.request.premiumDualLaneRequested, false);
  });
});

test('grant computes ordinary subagent docker rate from operator profile', async () => {
  await withTempDir('docker-lane-handshake-grant-ordinary', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const handshakeRoot = path.join(root, 'handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runDockerLaneHandshake({
      action: 'request',
      laneId: 'docker-agent-singer-linux-01',
      agentId: 'singer',
      agentClass: 'subagent',
      capabilities: [DOCKER_LANE_CAPABILITY],
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:50:00.000Z')
    });

    const report = await runDockerLaneHandshake({
      action: 'grant',
      laneId: 'docker-agent-singer-linux-01',
      agentId: 'singer',
      agentClass: 'subagent',
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:51:00.000Z')
    });

    assert.equal(report.status, 'granted');
    assert.equal(report.handshake.grant.billableRateMultiplier, 1);
    assert.equal(report.handshake.grant.billableRateUsdPerHour, 250);
    assert.equal(report.handshake.grant.premiumSaganMode, false);
    assert.equal(report.handshake.grant.ttlSeconds, DEFAULT_TTL_SECONDS);
  });
});

test('grant denies premium dual-lane requests for subagents', async () => {
  await withTempDir('docker-lane-handshake-deny-subagent-premium', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const handshakeRoot = path.join(root, 'handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runDockerLaneHandshake({
      action: 'request',
      laneId: 'docker-agent-hooke-linux-01',
      agentId: 'hooke',
      agentClass: 'subagent',
      capabilities: [DOCKER_LANE_CAPABILITY, NATIVE_LV32_CAPABILITY],
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:50:00.000Z')
    });

    const report = await runDockerLaneHandshake({
      action: 'grant',
      laneId: 'docker-agent-hooke-linux-01',
      agentId: 'hooke',
      agentClass: 'subagent',
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:51:00.000Z')
    });

    assert.equal(report.status, 'denied');
    assert.match(report.summary.denialReasons.join('\n'), /premium-sagan-only/);
  });
});

test('grant requires operator authorization for premium Sagan dual-lane mode and computes 1.5x rate when authorized', async () => {
  await withTempDir('docker-lane-handshake-sagan-premium', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const handshakeRoot = path.join(root, 'handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runDockerLaneHandshake({
      action: 'request',
      laneId: 'docker-agent-sagan-dual-01',
      agentId: 'sagan',
      agentClass: 'sagan',
      capabilities: [DOCKER_LANE_CAPABILITY, NATIVE_LV32_CAPABILITY],
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:50:00.000Z')
    });

    const denied = await runDockerLaneHandshake({
      action: 'grant',
      laneId: 'docker-agent-sagan-dual-01',
      agentId: 'sagan',
      agentClass: 'sagan',
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:51:00.000Z')
    });
    assert.equal(denied.status, 'denied');
    assert.match(denied.summary.denialReasons.join('\n'), /operator-authorization-required/);

    const requestPath = handshakePathForLane('docker-agent-sagan-dual-01', handshakeRoot);
    const existing = JSON.parse(await fs.readFile(requestPath, 'utf8'));
    existing.request.operatorAuthorizationRef = 'budget-auth://operator/session-2026-03-23';
    await writeJson(requestPath, existing);

    const granted = await runDockerLaneHandshake({
      action: 'grant',
      laneId: 'docker-agent-sagan-dual-01',
      agentId: 'sagan',
      agentClass: 'sagan',
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:52:00.000Z')
    });

    assert.equal(granted.status, 'granted');
    assert.equal(granted.handshake.grant.premiumSaganMode, true);
    assert.equal(granted.handshake.grant.billableRateMultiplier, PREMIUM_RATE_MULTIPLIER);
    assert.equal(granted.handshake.grant.billableRateUsdPerHour, 375);
  });
});

test('commit heartbeat and release keep the same handshake and permit active inspection', async () => {
  await withTempDir('docker-lane-handshake-life-cycle', async (root) => {
    const hostPlaneReportPath = path.join(root, 'host-plane.json');
    const operatorCostProfilePath = path.join(root, 'operator-cost-profile.json');
    const handshakeRoot = path.join(root, 'handshakes');
    await writeJson(hostPlaneReportPath, createHostPlaneReport());
    await writeJson(operatorCostProfilePath, createOperatorCostProfile());

    await runDockerLaneHandshake({
      action: 'request',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      agentClass: 'subagent',
      capabilities: [DOCKER_LANE_CAPABILITY],
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:50:00.000Z')
    });

    const granted = await runDockerLaneHandshake({
      action: 'grant',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      agentClass: 'subagent',
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:51:00.000Z')
    });

    const committed = await runDockerLaneHandshake({
      action: 'commit',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      leaseId: granted.handshake.grant.leaseId,
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:52:00.000Z')
    });
    assert.equal(committed.status, 'committed');
    assert.equal(committed.handshake.state, 'active');

    const renewed = await runDockerLaneHandshake({
      action: 'heartbeat',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      leaseId: granted.handshake.grant.leaseId,
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:53:00.000Z')
    });
    assert.equal(renewed.status, 'renewed');
    assert.equal(renewed.handshake.state, 'active');

    const activeInspect = await runDockerLaneHandshake({
      action: 'inspect',
      laneId: 'docker-agent-mill-linux-01',
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:53:30.000Z')
    });
    assert.equal(activeInspect.status, 'active');
    assert.equal(isHandshakeStale(activeInspect.handshake, Date.parse('2026-03-23T23:53:30.000Z')), false);

    const release = await runDockerLaneHandshake({
      action: 'release',
      laneId: 'docker-agent-mill-linux-01',
      agentId: 'mill',
      leaseId: granted.handshake.grant.leaseId,
      artifactPaths: ['tests/results/_agent/runtime/docker-lane-proof.json'],
      hostPlaneReportPath,
      operatorCostProfilePath,
      handshakeRoot,
      repoRoot: root,
      now: new Date('2026-03-23T23:54:00.000Z')
    });
    assert.equal(release.status, 'released');
    assert.equal(release.handshake.state, 'released');
    assert.deepEqual(release.handshake.release.artifactPaths, ['tests/results/_agent/runtime/docker-lane-proof.json']);
  });
});
