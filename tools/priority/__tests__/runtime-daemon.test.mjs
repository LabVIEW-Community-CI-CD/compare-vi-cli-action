#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { runRuntimeObserverLoop } from '../runtime-daemon.mjs';
import { compareviRuntimeTest } from '../runtime-supervisor.mjs';

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

function makeExecDeps() {
  const calls = [];
  return {
    calls,
    execFileFn: async (command, args, options) => {
      calls.push({ command, args, options });
      const checkoutPath = args[3];
      await mkdir(checkoutPath, { recursive: true });
      await writeFile(path.join(checkoutPath, '.git'), 'gitdir: mocked\n', 'utf8');
      return { stdout: '', stderr: '' };
    }
  };
}

test('runtime-daemon wrapper defaults to the comparevi adapter', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-wrapper-root-'));
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-wrapper-'));
  const deps = makeLeaseDeps();
  const execDeps = makeExecDeps();
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
      resolveRepoRootFn: () => repoRoot,
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 17, 0, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when maxCycles=1');
      },
      ...execDeps,
      ...deps
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.runtimeAdapter, 'comparevi');
  assert.equal(result.report.outcome, 'max-cycles-reached');
  assert.equal(heartbeat.runtimeAdapter, 'comparevi');
  assert.equal(heartbeat.cyclesCompleted, 1);
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(execDeps.calls.length, 1);
  assert.deepEqual(
    deps.calls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});

test('runtime-daemon wrapper schedules from the comparevi standing-priority cache when no lane is provided', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-comparevi-'));
  const runtimeDir = path.join('tests', 'results', '_agent', 'runtime');
  const deps = makeLeaseDeps();
  const execDeps = makeExecDeps();
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
      ...execDeps,
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
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(execDeps.calls.length, 1);
  assert.deepEqual(
    deps.calls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});

test('comparevi worker checkout allocator reuses an existing lane worktree path', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-reuse-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'personal-995'
  });
  await mkdir(checkoutPath, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), 'gitdir: reused\n', 'utf8');

  const prepared = await compareviRuntimeTest.prepareCompareviWorkerCheckout({
    repoRoot,
    repository: 'example/repo',
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-995'
      },
      stepOptions: {}
    },
    deps: {
      execFileFn: async () => {
        throw new Error('execFileFn should not run for reused worktrees');
      }
    }
  });

  assert.equal(prepared.status, 'reused');
  assert.equal(prepared.checkoutPath, checkoutPath);
});
