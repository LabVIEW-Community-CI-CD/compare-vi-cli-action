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
  const currentBranches = new Map();
  return {
    calls,
    execFileFn: async (command, args, options) => {
      calls.push({ command, args, options });
      if (command === 'git') {
        if (args[0] === 'worktree' && args[1] === 'add') {
          const checkoutPath = args[3];
          await mkdir(checkoutPath, { recursive: true });
          await writeFile(path.join(checkoutPath, '.git'), 'gitdir: mocked\n', 'utf8');
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'remote') {
          return { stdout: 'upstream\norigin\npersonal\n', stderr: '' };
        }
        if (args[0] === 'fetch') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'branch' && args[1] === '--show-current') {
          return { stdout: currentBranches.get(options.cwd) ?? '', stderr: '' };
        }
        if (args[0] === 'show-ref') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'checkout' && args[1] === '-B') {
          currentBranches.set(options.cwd, args[2]);
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'branch' && args[1] === '--set-upstream-to') {
          return { stdout: '', stderr: '' };
        }
      }
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
      branch: 'issue/origin-977-fork-policy-portability',
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
  const taskPacket = await readJson(path.join(runtimeDir, 'task-packet.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.runtimeAdapter, 'comparevi');
  assert.equal(result.report.outcome, 'max-cycles-reached');
  assert.equal(heartbeat.runtimeAdapter, 'comparevi');
  assert.equal(heartbeat.cyclesCompleted, 1);
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(heartbeat.activeLane.workerReady.status, 'ready');
  assert.equal(heartbeat.activeLane.workerBranch.status, 'attached');
  assert.equal(heartbeat.activeLane.workerBranch.branch, 'issue/origin-977-fork-policy-portability');
  assert.equal(taskPacket.objective.summary, 'Advance issue #977 on issue/origin-977-fork-policy-portability');
  assert.equal(taskPacket.helperSurface.preferred[0], 'pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1');
  assert.ok(execDeps.calls.some((entry) => entry.command === 'pwsh'));
  assert.ok(execDeps.calls.some((entry) => entry.command === 'git' && entry.args[0] === 'checkout'));
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
        title: 'Human go/no-go workflow',
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
  const taskPacket = await readJson(path.join(repoRoot, runtimeDir, 'task-packet.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.outcome, 'max-cycles-reached');
  assert.equal(result.report.lastDecision.source, 'comparevi-standing-priority-cache');
  assert.equal(result.report.lastDecision.activeLane.issue, 982);
  assert.equal(result.report.lastDecision.activeLane.branch, 'issue/origin-982-human-go-no-go-workflow');
  assert.equal(heartbeat.schedulerDecision.source, 'comparevi-standing-priority-cache');
  assert.equal(heartbeat.activeLane.issue, 982);
  assert.equal(heartbeat.activeLane.forkRemote, 'origin');
  assert.equal(heartbeat.activeLane.branch, 'issue/origin-982-human-go-no-go-workflow');
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(heartbeat.activeLane.workerReady.status, 'ready');
  assert.equal(heartbeat.activeLane.workerBranch.status, 'attached');
  assert.equal(taskPacket.objective.summary, 'Advance issue #982: Human go/no-go workflow on issue/origin-982-human-go-no-go-workflow');
  assert.equal(taskPacket.evidence.priority.cachePath, path.join(repoRoot, '.agent_priority_cache.json'));
  assert.ok(execDeps.calls.some((entry) => entry.command === 'git' && entry.args[0] === 'checkout'));
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

test('comparevi worker checkout path sanitizes traversal-only segments and keeps the root under repoRoot', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-sanitize-'));
  const { checkoutRoot, checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: '',
    laneId: '..'
  });

  assert.equal(checkoutRoot, path.join(repoRoot, '.runtime-worktrees', path.basename(repoRoot)));
  assert.equal(checkoutPath, path.join(checkoutRoot, 'runtime'));
});

test('comparevi worker bootstrap marks an allocated checkout ready after bootstrap passes', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-ready-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'personal-997'
  });
  await mkdir(path.join(checkoutPath, 'tools', 'priority'), { recursive: true });
  await writeFile(path.join(checkoutPath, 'tools', 'priority', 'bootstrap.ps1'), '# mocked bootstrap', 'utf8');

  const calls = [];
  const ready = await compareviRuntimeTest.bootstrapCompareviWorkerCheckout({
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-997'
      }
    },
    preparedWorker: {
      generatedAt: '2026-03-10T18:00:00.000Z',
      checkoutPath
    },
    deps: {
      execFileFn: async (command, args, options) => {
        calls.push({ command, args, options });
        return { stdout: '', stderr: '' };
      }
    }
  });

  assert.equal(ready.status, 'ready');
  assert.equal(ready.checkoutPath, checkoutPath);
  assert.equal(calls[0].command, 'pwsh');
});

test('comparevi worker bootstrap includes stderr in blocked bootstrap diagnostics', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-ready-stderr-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'personal-997'
  });
  await mkdir(path.join(checkoutPath, 'tools', 'priority'), { recursive: true });
  await writeFile(path.join(checkoutPath, 'tools', 'priority', 'bootstrap.ps1'), '# mocked bootstrap', 'utf8');

  const blocked = await compareviRuntimeTest.bootstrapCompareviWorkerCheckout({
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-997'
      }
    },
    preparedWorker: {
      generatedAt: '2026-03-10T18:00:00.000Z',
      checkoutPath
    },
    deps: {
      execFileFn: async () => {
        const error = new Error('bootstrap failed');
        error.stderr = 'bootstrap stderr';
        error.code = 7;
        throw error;
      }
    }
  });

  assert.equal(blocked.status, 'blocked');
  assert.equal(blocked.bootstrapExitCode, 7);
  assert.match(blocked.reason, /bootstrap failed/);
  assert.match(blocked.reason, /bootstrap stderr/);
});

test('comparevi worker activation attaches a ready checkout onto the deterministic lane branch', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-branch-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'personal-998'
  });
  await mkdir(checkoutPath, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), 'gitdir: mocked\n', 'utf8');

  const calls = [];
  const attached = await compareviRuntimeTest.activateCompareviWorkerLane({
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-998',
        forkRemote: 'personal',
        branch: 'issue/personal-998-runtime-worker-branch-activation'
      },
      stepOptions: {
        branch: 'issue/personal-998-runtime-worker-branch-activation'
      }
    },
    preparedWorker: {
      checkoutPath
    },
    workerReady: {
      readyAt: '2026-03-10T18:30:00.000Z',
      checkoutPath
    },
    deps: {
      execFileFn: async (command, args, options) => {
        calls.push({ command, args, options });
        if (command !== 'git') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'remote') {
          return { stdout: 'upstream\norigin\npersonal\n', stderr: '' };
        }
        if (args[0] === 'branch' && args[1] === '--show-current') {
          return { stdout: '', stderr: '' };
        }
        return { stdout: '', stderr: '' };
      }
    }
  });

  assert.equal(attached.status, 'attached');
  assert.equal(attached.branch, 'issue/personal-998-runtime-worker-branch-activation');
  assert.equal(attached.trackingRef, 'personal/issue/personal-998-runtime-worker-branch-activation');
  assert.deepEqual(attached.fetchedRemotes, ['upstream', 'origin', 'personal']);
  assert.ok(calls.some((entry) => entry.command === 'git' && entry.args[0] === 'checkout'));
});

test('comparevi worker activation blocks when the scheduler does not resolve a branch name', async () => {
  const blocked = await compareviRuntimeTest.activateCompareviWorkerLane({
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-998',
        forkRemote: 'origin'
      },
      stepOptions: {}
    },
    preparedWorker: {
      checkoutPath: 'D:/tmp/runtime-worker'
    },
    workerReady: {
      checkoutPath: 'D:/tmp/runtime-worker'
    },
    deps: {
      execFileFn: async () => {
        throw new Error('git should not run without a branch name');
      }
    }
  });

  assert.equal(blocked.status, 'blocked');
  assert.match(blocked.reason, /branch name/i);
});
