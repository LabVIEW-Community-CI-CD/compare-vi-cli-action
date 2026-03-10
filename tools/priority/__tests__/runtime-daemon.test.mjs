#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { runRuntimeObserverLoop } from '../runtime-daemon.mjs';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

function makeLeaseDeps() {
  const calls = [];
  return {
    calls,
    acquireWriterLeaseFn: async (options) => {
      calls.push({ type: 'acquire', options });
      return {
        action: 'acquire',
        status: 'acquired',
        scope: options.scope,
        owner: options.owner,
        checkedAt: '2026-03-10T17:00:00.000Z',
        lease: {
          leaseId: 'lease-daemon-1',
          owner: options.owner
        }
      };
    },
    releaseWriterLeaseFn: async (options) => {
      calls.push({ type: 'release', options });
      return {
        action: 'release',
        status: 'released',
        scope: options.scope,
        owner: options.owner,
        checkedAt: '2026-03-10T17:00:05.000Z',
        lease: {
          leaseId: options.leaseId,
          owner: options.owner
        }
      };
    }
  };
}

test('runtime-daemon wrapper defaults to the comparevi adapter', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-wrapper-'));
  const deps = makeLeaseDeps();
  let tick = 0;
  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-977',
      issue: 977,
      forkRemote: 'origin',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 17, 0, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when maxCycles=1');
      },
      ...deps
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.runtimeAdapter, 'comparevi');
  assert.equal(result.report.outcome, 'max-cycles-reached');
  assert.equal(heartbeat.runtimeAdapter, 'comparevi');
  assert.equal(heartbeat.cyclesCompleted, 1);
  assert.deepEqual(
    deps.calls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});

test('runtime-daemon wrapper schedules from the comparevi standing-priority cache when no lane is provided', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-comparevi-'));
  const runtimeDir = path.join('tests', 'results', '_agent', 'runtime');
  const deps = makeLeaseDeps();
  let tick = 0;
  await writeFile(
    path.join(repoRoot, '.agent_priority_cache.json'),
    `${JSON.stringify(
      {
        number: 2,
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action-fork/issues/2',
        state: 'open',
        labels: ['fork-standing-priority'],
        mirrorOf: {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          number: 982,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/982'
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const result = await runRuntimeObserverLoop(
    {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runtimeDir,
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      resolveRepoRootFn: () => repoRoot,
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 17, 30, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when maxCycles=1');
      },
      ...deps
    }
  );

  const heartbeat = await readJson(path.join(repoRoot, runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.outcome, 'max-cycles-reached');
  assert.equal(result.report.lastDecision.source, 'comparevi-standing-priority-cache');
  assert.equal(result.report.lastDecision.activeLane.issue, 982);
  assert.equal(heartbeat.schedulerDecision.source, 'comparevi-standing-priority-cache');
  assert.equal(heartbeat.activeLane.issue, 982);
  assert.equal(heartbeat.activeLane.forkRemote, 'origin');
  assert.deepEqual(
    deps.calls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});
