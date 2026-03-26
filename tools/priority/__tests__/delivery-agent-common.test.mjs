#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'lib', 'delivery-agent-common.js');

let builtModulePromise = null;

async function loadModule() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(buildResult.status, 0, [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'));
    builtModulePromise = import(`${pathToFileURL(distModulePath).href}?cache=${Date.now()}`);
  }
  return builtModulePromise;
}

function buildPaths(runtimeDirPath = path.join(repoRoot, 'tests', 'results', '_agent', 'runtime')) {
  return {
    runtimeDirPath,
    deliveryStatePath: path.join(runtimeDirPath, 'delivery-agent-state.json'),
  };
}

test('resolveDeliveryStateForStatus rejects stale heartbeat epochs even when daemonAlive is true', async () => {
  const { resolveDeliveryStateForStatus } = await loadModule();
  const now = Date.now();
  const deliveryGeneratedAt = new Date(now - 5_000).toISOString();
  const heartbeatGeneratedAt = new Date(now - 60_000).toISOString();
  const managerStartedAt = new Date(now - 10_000);
  const daemonStartedAt = new Date(now - 9_000);

  const result = resolveDeliveryStateForStatus({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: 'tests/results/_agent/runtime',
    deliveryState: {
      schema: 'priority/delivery-agent-runtime-state@v1',
      generatedAt: deliveryGeneratedAt,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'blocked',
      laneLifecycle: 'blocked',
      activeCodingLanes: 0,
      activeLane: {
        schema: 'priority/delivery-agent-lane-state@v1',
        generatedAt: deliveryGeneratedAt,
        laneId: 'origin-1010',
        issue: 1010,
        branch: 'issue/origin-1010-example',
        laneLifecycle: 'blocked',
      },
    },
    heartbeat: {
      schema: 'priority/runtime-observer-heartbeat@v1',
      generatedAt: heartbeatGeneratedAt,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      outcome: 'lane-tracked',
      activeLane: {
        laneId: 'origin-959',
        issue: 959,
        branch: 'issue/origin-959-example',
      },
    },
    runtimeState: null,
    taskPacket: null,
    paths: buildPaths(),
    managerStartedAt,
    daemonStartedAt,
    daemonAlive: true,
  });

  assert.equal(result.state?.activeLane?.issue, 1010);
  assert.equal(result.diagnostics.usedHeartbeat, false);
  assert.equal(result.diagnostics.usedRuntimeState, false);
  assert.equal(result.diagnostics.reason, 'stale-before-current-manager');
});

test('resolveDeliveryStateForStatus falls back to fresh runtime state when heartbeat predates the current epoch', async () => {
  const { resolveDeliveryStateForStatus } = await loadModule();
  const now = Date.now();
  const deliveryGeneratedAt = new Date(now - 90_000).toISOString();
  const heartbeatGeneratedAt = new Date(now - 60_000).toISOString();
  const runtimeGeneratedAt = new Date(now - 5_000).toISOString();
  const managerStartedAt = new Date(now - 10_000);
  const daemonStartedAt = new Date(now - 9_000);

  const result = resolveDeliveryStateForStatus({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: 'tests/results/_agent/runtime',
    deliveryState: {
      schema: 'priority/delivery-agent-runtime-state@v1',
      generatedAt: deliveryGeneratedAt,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'blocked',
      laneLifecycle: 'blocked',
      activeCodingLanes: 0,
      activeLane: {
        schema: 'priority/delivery-agent-lane-state@v1',
        generatedAt: deliveryGeneratedAt,
        laneId: 'origin-1010',
        issue: 1010,
        branch: 'issue/origin-1010-example',
        laneLifecycle: 'blocked',
      },
    },
    heartbeat: {
      schema: 'priority/runtime-observer-heartbeat@v1',
      generatedAt: heartbeatGeneratedAt,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      outcome: 'lane-tracked',
      activeLane: {
        laneId: 'origin-959',
        issue: 959,
        branch: 'issue/origin-959-example',
      },
    },
    runtimeState: {
      schema: 'priority/runtime-supervisor-state@v1',
      generatedAt: runtimeGeneratedAt,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      lifecycle: {
        status: 'coding',
      },
      activeLane: {
        laneId: 'origin-2010',
        issue: 2010,
        branch: 'issue/origin-2010-fail-closed',
        forkRemote: 'origin',
      },
    },
    taskPacket: {
      schema: 'priority/runtime-worker-task-packet@v1',
      generatedAt: runtimeGeneratedAt,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      laneId: 'origin-2010',
      status: 'coding',
      branch: {
        name: 'issue/origin-2010-fail-closed',
        forkRemote: 'origin',
      },
      evidence: {
        delivery: {
          selectedActionType: 'advance-standing-issue',
          laneLifecycle: 'coding',
        },
      },
    },
    paths: buildPaths(),
    managerStartedAt,
    daemonStartedAt,
    daemonAlive: true,
  });

  assert.equal(result.state?.activeLane?.issue, 2010);
  assert.equal(result.state?.activeLane?.branch, 'issue/origin-2010-fail-closed');
  assert.equal(result.diagnostics.usedHeartbeat, false);
  assert.equal(result.diagnostics.usedRuntimeState, true);
  assert.equal(result.diagnostics.reason, 'runtime-state-current');
});

test('quarantineStaleRuntimeReceipts rotates stale active runtime receipts into the startup quarantine folder', async (t) => {
  const { getArtifactPaths, quarantineStaleRuntimeReceipts } = await loadModule();
  const runtimeDirPath = await mkdtemp(path.join(os.tmpdir(), 'delivery-agent-runtime-epoch-'));
  t.after(async () => {
    await rm(runtimeDirPath, { recursive: true, force: true });
  });

  const managerStartedAt = new Date('2026-03-26T16:53:24.000Z');
  const paths = getArtifactPaths(repoRoot, runtimeDirPath);
  await writeFile(
    paths.observerHeartbeatPath,
    `${JSON.stringify({
      schema: 'priority/runtime-observer-heartbeat@v1',
      generatedAt: '2026-03-11T16:22:59.000Z',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      outcome: 'lane-tracked',
    }, null, 2)}\n`,
    'utf8',
  );
  await writeFile(
    paths.hostSignalPath,
    `${JSON.stringify({
      schema: 'priority/delivery-host-signal@v1',
      generatedAt: '2026-03-11T16:22:59.000Z',
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      status: 'native-wsl',
    }, null, 2)}\n`,
    'utf8',
  );
  await writeFile(paths.runtimeStatePath, '{not-json}\n', 'utf8');

  const result = quarantineStaleRuntimeReceipts({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    runtimeDir: runtimeDirPath,
    paths,
    runtimeEpochId: '2026-03-26T16-53-24-000Z-labview-community-ci-cd-compare-vi-cli-action',
    managerStartedAt,
  });

  assert.equal(result.entryCount, 3);
  assert.equal(result.quarantineDirPath, path.join(paths.runtimeQuarantineRootPath, result.runtimeEpochId));
  assert.equal(await readFile(path.join(result.quarantineDirPath, 'observer-heartbeat.json'), 'utf8').then((text) => JSON.parse(text).generatedAt), '2026-03-11T16:22:59.000Z');
  assert.equal(await readFile(path.join(result.quarantineDirPath, 'daemon-host-signal.json'), 'utf8').then((text) => JSON.parse(text).generatedAt), '2026-03-11T16:22:59.000Z');
  assert.equal(await readFile(path.join(result.quarantineDirPath, 'runtime-state.json'), 'utf8'), '{not-json}\n');
});
