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

function makeRuntimeBranchContract() {
  return {
    schema: 'branch-classes/v1',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    repositoryPlanes: [
      {
        id: 'upstream',
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
        laneBranchPrefix: 'issue/'
      },
      {
        id: 'origin',
        repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
        laneBranchPrefix: 'issue/origin-'
      },
      {
        id: 'personal',
        repositories: ['svelderrainruiz/compare-vi-cli-action'],
        laneBranchPrefix: 'issue/personal-'
      }
    ],
    classes: [
      {
        id: 'lane',
        repositoryRoles: ['upstream', 'fork'],
        branchPatterns: ['issue/*'],
        purpose: 'lane',
        prSourceAllowed: true,
        prTargetAllowed: false,
        mergePolicy: 'n/a'
      }
    ],
    allowedTransitions: [
      {
        from: 'lane',
        action: 'promote',
        to: 'upstream-integration',
        via: 'pull-request'
      }
    ],
    planeTransitions: [
      {
        from: 'origin',
        action: 'promote',
        to: 'upstream',
        via: 'pull-request',
        branchClass: 'lane'
      },
      {
        from: 'personal',
        action: 'promote',
        to: 'upstream',
        via: 'pull-request',
        branchClass: 'lane'
      }
    ]
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
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
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
  assert.equal(taskPacket.helperSurface.preferred[0], 'node tools/npm/run-script.mjs priority:github:metadata:apply');
  assert.ok(!taskPacket.helperSurface.preferred.includes('pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1'));
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
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
      resolveStandingPriorityForRepoFn: async () => ({
        found: null
      }),
      classifyNoStandingPriorityConditionFn: async () => ({
        status: 'error'
      }),
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

test('comparevi worker checkout allocator refreshes and reuses an existing lane worktree path', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-reuse-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'personal-995'
  });
  const worktreeAdminDir = path.join(repoRoot, '.git', 'worktrees', 'personal-995');
  await mkdir(checkoutPath, { recursive: true });
  await mkdir(worktreeAdminDir, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), 'gitdir: C:/stale/windows/path\n', 'utf8');
  await writeFile(path.join(worktreeAdminDir, 'gitdir'), '/mnt/c/stale/linux/path/.git\n', 'utf8');
  const calls = [];

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
      platform: 'linux',
      execFileFn: async (command, args, options) => {
        calls.push({ command, args, options });
        if (command !== 'git') {
          throw new Error(`unexpected command: ${command}`);
        }
        if (args[0] === 'remote') {
          if (args[1] === 'get-url' && args[2] === 'origin') {
            return { stdout: 'https://github.com/example/repo-fork\n', stderr: '' };
          }
          if (args[1] === 'get-url' && args[2] === '--push' && args[3] === 'origin') {
            return { stdout: 'https://github.com/example/repo-fork\n', stderr: '' };
          }
          if (args[1] === 'set-url' && args[2] === '--push' && args[3] === 'origin') {
            assert.equal(args[4], 'git@github.com:example/repo-fork.git');
            return { stdout: '', stderr: '' };
          }
          return { stdout: 'upstream\norigin\n', stderr: '' };
        }
        if (args[0] === 'status' && args[1] === '--porcelain' && args[2] === '--untracked-files=all') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'fetch' && args[1] === 'upstream' && args[2] === '--prune') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'checkout' && args[1] === '--force' && args[2] === '--detach' && args[3] === 'upstream/develop') {
          return { stdout: '', stderr: '' };
        }
        throw new Error(`unexpected git args: ${args.join(' ')}`);
      }
    }
  });

  assert.equal(prepared.status, 'reused');
  assert.equal(prepared.checkoutPath, checkoutPath);
  assert.equal(prepared.ref, 'upstream/develop');
  assert.deepEqual(prepared.fetchedRemotes, ['upstream']);
  assert.deepEqual(prepared.pushRemotesNormalized, ['origin']);
  assert.deepEqual(prepared.worktreeStateRepair, { repaired: false, dirtyEntries: [] });
  assert.equal(
    await readFile(path.join(checkoutPath, '.git'), 'utf8'),
    `gitdir: ${path.relative(checkoutPath, path.join(repoRoot, '.git', 'worktrees', 'personal-995')).replace(/\\/g, '/')}\n`
  );
  assert.equal(
    await readFile(path.join(worktreeAdminDir, 'gitdir'), 'utf8'),
    `${path.relative(worktreeAdminDir, path.join(checkoutPath, '.git')).replace(/\\/g, '/')}\n`
  );
  assert.ok(calls.some((entry) => entry.command === 'git' && entry.args[0] === 'fetch' && entry.args[1] === 'upstream'));
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'remote' &&
        entry.args[1] === 'set-url' &&
        entry.args[2] === '--push' &&
        entry.args[3] === 'origin'
    )
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'checkout' &&
        entry.args.includes('--force') &&
        entry.args.includes('--detach')
    )
  );
});

test('comparevi worker checkout allocator quarantines stale runtime drift before recreating a lane worktree', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-repair-'));
  const laneId = 'origin-959';
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId
  });
  const worktreeAdminDir = path.join(repoRoot, '.git', 'worktrees', laneId);
  await mkdir(checkoutPath, { recursive: true });
  await mkdir(worktreeAdminDir, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), 'gitdir: C:/stale/windows/path\n', 'utf8');
  await writeFile(path.join(worktreeAdminDir, 'gitdir'), '/mnt/c/stale/linux/path/.git\n', 'utf8');

  const calls = [];
  const prepared = await compareviRuntimeTest.prepareCompareviWorkerCheckout({
    repoRoot,
    repository: 'example/repo',
    schedulerDecision: {
      activeLane: {
        laneId
      },
      stepOptions: {}
    },
    deps: {
      platform: 'linux',
      execFileFn: async (command, args, options) => {
        calls.push({ command, args, options });
        if (command !== 'git') {
          throw new Error(`unexpected command: ${command}`);
        }
        if (args[0] === 'status' && args[1] === '--porcelain' && args[2] === '--untracked-files=all') {
          return {
            stdout: 'M  tools/priority/delivery-agent.mjs\n',
            stderr: ''
          };
        }
        if (args[0] === 'remote') {
          if (args[1] === 'get-url' && args[2] === 'origin') {
            return { stdout: 'https://github.com/example/repo-fork\n', stderr: '' };
          }
          if (args[1] === 'get-url' && args[2] === '--push' && args[3] === 'origin') {
            return { stdout: 'https://github.com/example/repo-fork\n', stderr: '' };
          }
          if (args[1] === 'set-url' && args[2] === '--push' && args[3] === 'origin') {
            return { stdout: '', stderr: '' };
          }
          return { stdout: 'upstream\norigin\n', stderr: '' };
        }
        if (args[0] === 'fetch' && args[1] === 'upstream' && args[2] === '--prune') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'worktree' && args[1] === 'remove' && args[2] === '--force') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'worktree' && args[1] === 'prune') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'worktree' && args[1] === 'add' && args[2] === '--detach') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'checkout' && args[1] === '--force' && args[2] === '--detach' && args[3] === 'upstream/develop') {
          return { stdout: '', stderr: '' };
        }
        throw new Error(`unexpected git args: ${args.join(' ')}`);
      }
    }
  });

  assert.equal(prepared.status, 'created');
  assert.equal(prepared.worktreeStateRepair.repaired, false);
  assert.equal(prepared.worktreeStateRepair.quarantined, true);
  assert.deepEqual(prepared.worktreeStateRepair.dirtyEntries, ['M  tools/priority/delivery-agent.mjs']);
  assert.equal(prepared.worktreeStateRepair.quarantineReason, 'dirty-existing-checkout');
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'worktree' &&
        entry.args[1] === 'remove' &&
        entry.args[2] === '--force'
    )
  );
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'worktree' &&
        entry.args[1] === 'add' &&
        entry.args[2] === '--detach'
    )
  );
});

test('comparevi worker checkout allocator rewrites new WSL worktree pointers into cross-plane relative metadata', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-create-relative-'));
  const laneId = 'origin-1201';
  const slotId = 'worker-slot-1';
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId,
    slotId
  });
  const worktreeAdminDir = path.join(repoRoot, '.git', 'worktrees', slotId);

  const prepared = await compareviRuntimeTest.prepareCompareviWorkerCheckout({
    repoRoot,
    repository: 'example/repo',
    schedulerDecision: {
      activeLane: {
        laneId
      },
      stepOptions: {}
    },
    deps: {
      platform: 'linux',
      execFileFn: async (command, args, options) => {
        if (command !== 'git') {
          throw new Error(`unexpected command: ${command}`);
        }
        if (args[0] === 'rev-parse' && args[1] === '--git-common-dir') {
          return { stdout: '.git\n', stderr: '' };
        }
        if (args[0] === 'worktree' && args[1] === 'add') {
          await mkdir(checkoutPath, { recursive: true });
          await mkdir(worktreeAdminDir, { recursive: true });
          await writeFile(path.join(checkoutPath, '.git'), `gitdir: /mnt/c/mock/.git/worktrees/${slotId}\n`, 'utf8');
          await writeFile(path.join(worktreeAdminDir, 'gitdir'), `/mnt/c/mock/.runtime-worktrees/example-repo/${slotId}/.git\n`, 'utf8');
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'remote') {
          if (args[1] === 'set-url' && args[2] === '--push' && args[3] === 'origin') {
            return { stdout: '', stderr: '' };
          }
          if (args[1] === 'get-url' && args[2] === 'origin') {
            return { stdout: 'https://github.com/example/repo-fork\n', stderr: '' };
          }
          if (args[1] === 'get-url' && args[2] === '--push' && args[3] === 'origin') {
            return { stdout: 'git@github.com:example/repo-fork.git\n', stderr: '' };
          }
          return { stdout: 'upstream\norigin\n', stderr: '' };
        }
        throw new Error(`unexpected git args: ${args.join(' ')}`);
      }
    }
  });

  assert.equal(prepared.status, 'created');
  assert.equal(prepared.slotId, slotId);
  assert.equal(
    await readFile(path.join(checkoutPath, '.git'), 'utf8'),
    `gitdir: ${path.relative(checkoutPath, worktreeAdminDir).replace(/\\/g, '/')}\n`
  );
  assert.equal(
    await readFile(path.join(worktreeAdminDir, 'gitdir'), 'utf8'),
    `${path.relative(worktreeAdminDir, path.join(checkoutPath, '.git')).replace(/\\/g, '/')}\n`
  );
});

test('comparevi worktree scrub repairs stale /work registrations and clears initializing locks', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worktree-scrub-'));
  const runtimeRoot = path.join(repoRoot, '.runtime-worktrees', 'example-repo-fork');
  const laneId = 'origin-10';
  const checkoutPath = path.join(runtimeRoot, laneId);
  const worktreeAdminDir = path.join(repoRoot, '.git', 'worktrees', laneId);

  await mkdir(checkoutPath, { recursive: true });
  await mkdir(worktreeAdminDir, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), `gitdir: /work/.git/worktrees/${laneId}\n`, 'utf8');
  await writeFile(path.join(worktreeAdminDir, 'gitdir'), `/work/.runtime-worktrees/example-repo-fork/${laneId}/.git\n`, 'utf8');
  await writeFile(path.join(worktreeAdminDir, 'locked'), 'initializing\n', 'utf8');

  const pruneCalls = [];
  const report = await compareviRuntimeTest.repairRegisteredWorktreeGitPointers({
    repoRoot,
    deps: {
      execFileFn: async (command, args) => {
        if (command === 'git' && args[0] === 'rev-parse' && args[1] === '--git-common-dir') {
          return { stdout: '.git\n', stderr: '' };
        }
        pruneCalls.push({ command, args });
        return { stdout: '', stderr: '' };
      }
    }
  });

  assert.deepEqual(report.unresolved, []);
  assert.equal(report.repaired.length, 1);
  assert.equal(report.repaired[0].laneSegment, laneId);
  assert.equal(report.repaired[0].checkoutPath, checkoutPath);
  assert.equal(report.unlocked.length, 1);
  assert.equal(
    await readFile(path.join(checkoutPath, '.git'), 'utf8'),
    `gitdir: ${path.relative(checkoutPath, worktreeAdminDir).replace(/\\/g, '/')}\n`
  );
  assert.equal(
    await readFile(path.join(worktreeAdminDir, 'gitdir'), 'utf8'),
    `${path.relative(worktreeAdminDir, path.join(checkoutPath, '.git')).replace(/\\/g, '/')}\n`
  );
  await assert.rejects(readFile(path.join(worktreeAdminDir, 'locked'), 'utf8'));
  assert.deepEqual(pruneCalls, [{ command: 'git', args: ['worktree', 'prune', '--verbose', '--expire', 'now'] }]);
});

test('comparevi worker checkout allocator reuses runtime worktrees from a clean worktree root via the git common dir', async () => {
  const commonRepoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-common-root-'));
  const repoRoot = path.join(commonRepoRoot, 'repair');
  const laneId = 'origin-959';
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId
  });
  const worktreeAdminDir = path.join(commonRepoRoot, '.git', 'worktrees', laneId);

  await mkdir(checkoutPath, { recursive: true });
  await mkdir(worktreeAdminDir, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), `gitdir: /mnt/c/mock/.git/worktrees/${laneId}\n`, 'utf8');
  await writeFile(path.join(worktreeAdminDir, 'gitdir'), `/mnt/c/mock/.runtime-worktrees/example-repo/${laneId}/.git\n`, 'utf8');

  const prepared = await compareviRuntimeTest.prepareCompareviWorkerCheckout({
    repoRoot,
    repository: 'example/repo',
    schedulerDecision: {
      activeLane: {
        laneId
      },
      stepOptions: {}
    },
    deps: {
      platform: 'linux',
      execFileFn: async (command, args) => {
        if (command !== 'git') {
          throw new Error(`unexpected command: ${command}`);
        }
        if (args[0] === 'rev-parse' && args[1] === '--git-common-dir') {
          return { stdout: `${path.join(commonRepoRoot, '.git')}\n`, stderr: '' };
        }
        if (args[0] === 'status') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'remote') {
          if (args[1] === 'get-url' && args[2] === 'origin') {
            return { stdout: 'https://github.com/example/repo-fork\n', stderr: '' };
          }
          if (args[1] === 'get-url' && args[2] === '--push' && args[3] === 'origin') {
            return { stdout: 'git@github.com:example/repo-fork.git\n', stderr: '' };
          }
          return { stdout: 'upstream\norigin\n', stderr: '' };
        }
        if (args[0] === 'fetch' || (args[0] === 'checkout' && args[1] === '--force' && args[2] === '--detach')) {
          return { stdout: '', stderr: '' };
        }
        throw new Error(`unexpected git args: ${args.join(' ')}`);
      }
    }
  });

  assert.equal(prepared.status, 'reused');
  assert.equal(
    await readFile(path.join(checkoutPath, '.git'), 'utf8'),
    `gitdir: ${path.relative(checkoutPath, worktreeAdminDir).replace(/\\/g, '/')}\n`
  );
  assert.equal(
    await readFile(path.join(worktreeAdminDir, 'gitdir'), 'utf8'),
    `${path.relative(worktreeAdminDir, path.join(checkoutPath, '.git')).replace(/\\/g, '/')}\n`
  );
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

test('comparevi worker path containment helper treats the root itself as within scope', () => {
  const runtimeRoot = path.join('C:', 'repo', '.runtime-worktrees');
  assert.equal(compareviRuntimeTest.isPathWithin(runtimeRoot, runtimeRoot), true);
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
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'pwsh' &&
        entry.args.includes('-File') &&
        entry.args[entry.args.length - 1] === path.join(checkoutPath, 'tools', 'priority', 'bootstrap.ps1')
    )
  );
});

test('comparevi worker bootstrap configures lane lease env and reuses existing lane lease owner', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-ready-lease-env-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'origin-997'
  });
  await mkdir(path.join(checkoutPath, 'tools', 'priority'), { recursive: true });
  await writeFile(path.join(checkoutPath, 'tools', 'priority', 'bootstrap.ps1'), '# mocked bootstrap', 'utf8');
  const leaseRoot = path.resolve(checkoutPath, '.git/worktrees/origin-997', 'agent-writer-leases');
  await mkdir(leaseRoot, { recursive: true });
  await writeFile(
    path.join(leaseRoot, 'workspace.json'),
    `${JSON.stringify({ owner: 'persisted-lane-owner' }, null, 2)}\n`,
    'utf8'
  );

  const calls = [];
  const ready = await compareviRuntimeTest.bootstrapCompareviWorkerCheckout({
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-997'
      }
    },
    preparedWorker: {
      generatedAt: '2026-03-10T18:00:00.000Z',
      checkoutPath
    },
    deps: {
      execFileFn: async (command, args, options) => {
        calls.push({ command, args, options });
        if (command === 'git' && args[0] === 'rev-parse' && args[1] === '--git-dir') {
          return { stdout: '.git/worktrees/origin-997\n', stderr: '' };
        }
        return { stdout: '', stderr: '' };
      }
    }
  });

  assert.equal(ready.status, 'ready');
  const bootstrapCall = calls.find((entry) => entry.command === 'pwsh');
  assert.ok(bootstrapCall, 'expected bootstrap pwsh call');
  assert.equal(
    bootstrapCall.options.env.AGENT_WRITER_LEASE_ROOT,
    path.resolve(checkoutPath, '.git/worktrees/origin-997', 'agent-writer-leases')
  );
  assert.equal(bootstrapCall.options.env.AGENT_WRITER_LEASE_OWNER, 'persisted-lane-owner');
  assert.equal(bootstrapCall.options.env.AGENT_WRITER_LEASE_FORCE_TAKEOVER, '1');
  assert.equal(bootstrapCall.options.env.AGENT_WRITER_LEASE_STALE_SECONDS, '0');
});

test('comparevi worker bootstrap activates the lane branch before invoking bootstrap', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-ready-branch-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'origin-997'
  });
  await mkdir(path.join(checkoutPath, 'tools', 'priority'), { recursive: true });
  await writeFile(path.join(checkoutPath, 'tools', 'priority', 'bootstrap.ps1'), '# mocked bootstrap', 'utf8');

  const branchName = 'issue/origin-997-bootstrap-branch-first';
  const calls = [];
  const ready = await compareviRuntimeTest.bootstrapCompareviWorkerCheckout({
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-997',
        forkRemote: 'origin',
        branch: branchName
      },
      stepOptions: {
        branch: branchName
      }
    },
    preparedWorker: {
      generatedAt: '2026-03-10T18:00:00.000Z',
      checkoutPath
    },
    deps: {
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
      execFileFn: async (command, args, options) => {
        calls.push({ command, args, options });
        if (command !== 'git') {
          return { stdout: '', stderr: '' };
        }
        if (args[0] === 'remote') {
          return { stdout: 'upstream\norigin\n', stderr: '' };
        }
        if (args[0] === 'branch' && args[1] === '--show-current') {
          return { stdout: '', stderr: '' };
        }
        return { stdout: '', stderr: '' };
      }
    }
  });

  assert.equal(ready.status, 'ready');
  assert.ok(
    calls.some(
      (entry) =>
        entry.command === 'git' &&
        entry.args[0] === 'checkout' &&
        entry.args.includes('--force') &&
        entry.args.includes(branchName)
    )
  );
  assert.equal(calls[calls.length - 1].command, 'pwsh');
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

test('comparevi worker bootstrap fails closed when the branch prefix conflicts with the fork plane contract', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-ready-branch-conflict-'));
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
        laneId: 'personal-997',
        forkRemote: 'personal',
        branch: 'issue/origin-997-branch-conflict'
      },
      stepOptions: {
        branch: 'issue/origin-997-branch-conflict'
      }
    },
    preparedWorker: {
      generatedAt: '2026-03-10T18:00:00.000Z',
      checkoutPath
    },
    deps: {
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
      execFileFn: async () => {
        throw new Error('git should not run when the branch prefix conflicts with the plane contract');
      }
    }
  });

  assert.equal(blocked.status, 'blocked');
  assert.match(blocked.reason, /does not match lane branch prefix 'issue\/personal-'/i);
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
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
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
  assert.ok(calls.some((entry) => entry.command === 'git' && entry.args[0] === 'checkout' && entry.args.includes('--force')));
});

test('comparevi worker activation fails closed when the branch prefix conflicts with the fork plane contract', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-daemon-worker-branch-conflict-'));
  const { checkoutPath } = compareviRuntimeTest.resolveCompareviWorkerCheckoutPath({
    repoRoot,
    repository: 'example/repo',
    laneId: 'origin-998'
  });
  await mkdir(checkoutPath, { recursive: true });
  await writeFile(path.join(checkoutPath, '.git'), 'gitdir: mocked\n', 'utf8');

  const blocked = await compareviRuntimeTest.activateCompareviWorkerLane({
    schedulerDecision: {
      activeLane: {
        laneId: 'origin-998',
        forkRemote: 'origin',
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
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
      execFileFn: async () => {
        throw new Error('git should not run when the branch prefix conflicts with the plane contract');
      }
    }
  });

  assert.equal(blocked.status, 'blocked');
  assert.match(blocked.reason, /does not match lane branch prefix 'issue\/origin-'/i);
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

test('comparevi planner prefers live standing issue data for the target repository', async () => {
  const decision = await compareviRuntimeTest.planCompareviRuntimeStep({
    repoRoot: '/tmp/repo',
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    options: {
      repo: 'svelderrainruiz/compare-vi-cli-action'
    },
    explicitStepOptions: {},
    deps: {
      loadBranchClassContractFn: () => makeRuntimeBranchContract(),
      resolveStandingPriorityForRepoFn: async () => ({
        found: {
          number: 315,
          label: 'fork-standing-priority',
          repoSlug: 'svelderrainruiz/compare-vi-cli-action',
          source: 'gh'
        }
      }),
      ghIssueFetcher: async () => ({
        number: 315,
        title: 'Runtime daemon: consume task packets through a bounded worker-turn receipt seam',
        state: 'open',
        updatedAt: '2026-03-10T00:00:00Z',
        url: 'https://github.com/svelderrainruiz/compare-vi-cli-action/issues/315',
        labels: [{ name: 'fork-standing-priority' }],
        assignees: [],
        milestone: null,
        comments: 0,
        body:
          '<!-- upstream-issue-url: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1004 -->\n\nBody'
      }),
      restIssueFetcher: async () => null
    }
  });

  assert.equal(decision.source, 'comparevi-standing-priority-live');
  assert.equal(decision.outcome, 'selected');
  assert.equal(decision.stepOptions.issue, 1004);
  assert.equal(decision.stepOptions.forkRemote, 'personal');
  assert.equal(decision.artifacts.standingIssueNumber, 315);
  assert.equal(decision.artifacts.mirrorOf.number, 1004);
});

test('comparevi execution closes the fork mirror and advances to the next development issue', async () => {
  const handoffCalls = [];
  const closeCalls = [];
  const ghFetchCalls = [];
  const issueLabels = new Map([
    [315, ['fork-standing-priority']],
    [313, []]
  ]);
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'svelderrainruiz/compare-vi-cli-action'
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot: '/tmp/repo',
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-1004',
        issue: 1004
      },
      artifacts: {
        standingRepository: 'svelderrainruiz/compare-vi-cli-action',
        standingIssueNumber: 315,
        mirrorOf: {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          number: 1004,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1004'
        },
        cadence: false
      }
    },
    deps: {
      listRepoOpenIssuesFn: async () => [
        {
          number: 315,
          title: '[P1] Current mirror',
          body: 'body',
          labels: [{ name: 'fork-standing-priority' }],
          createdAt: '2026-03-10T00:00:00Z'
        },
        {
          number: 314,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: [],
          createdAt: '2026-03-08T00:00:00Z'
        },
        {
          number: 313,
          title: '[P1] Next development issue',
          body: 'body',
          labels: [],
          createdAt: '2026-03-09T00:00:00Z'
        },
        {
          number: 299,
          title: '[cadence] Package stream freshness alert',
          body: '<!-- cadence-check:package-staleness -->',
          labels: [],
          createdAt: '2026-03-01T00:00:00Z'
        }
      ],
      handoffGhRunner: (args) => {
        handoffCalls.push(args);
        if (args[0] === 'issue' && args[1] === 'edit') {
          const issueNumber = Number(args[2]);
          const labels = new Set(issueLabels.get(issueNumber) ?? []);
          const addIndex = args.indexOf('--add-label');
          if (addIndex >= 0) {
            labels.add(args[addIndex + 1]);
          }
          const removeIndex = args.indexOf('--remove-label');
          if (removeIndex >= 0) {
            labels.delete(args[removeIndex + 1]);
          }
          issueLabels.set(issueNumber, Array.from(labels));
          return '';
        }
        if (args[0] === 'issue' && args[1] === 'view') {
          const issueNumber = Number(args[2]);
          return JSON.stringify({
            number: issueNumber,
            labels: (issueLabels.get(issueNumber) ?? []).map((name) => ({ name }))
          });
        }
        if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
          if (args.includes('fork-standing-priority')) {
            return JSON.stringify([{ number: 315, labels: [{ name: 'fork-standing-priority' }] }]);
          }
          return '[]';
        }
        return '';
      },
      handoffSyncFn: async () => {},
      patchIssueLabelsFn: (_repoRoot, _repoSlug, issueNumber, labels) => {
        issueLabels.set(Number(issueNumber), Array.from(labels));
      },
      ghIssueFetcher: async ({ args }) => {
        ghFetchCalls.push(args);
        return {
          number: 314,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          updated_at: '2026-03-08T00:00:00Z',
          html_url: 'https://github.com/svelderrainruiz/compare-vi-cli-action/issues/314',
          url: 'https://api.github.com/repos/svelderrainruiz/compare-vi-cli-action/issues/314',
          labels: [],
          assignees: [],
          milestone: null,
          comments: [
            {
              body: 'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
            }
          ]
        };
      },
      closeIssueFn: async (payload) => {
        closeCalls.push(payload);
      }
    }
  });

  assert.equal(execution.outcome, 'mirror-closed-advanced');
  assert.equal(execution.stopLoop, false);
  assert.equal(execution.details.nextStandingIssueNumber, 313);
  assert.deepEqual(issueLabels.get(315), []);
  assert.deepEqual(issueLabels.get(313), ['fork-standing-priority']);
  assert.ok(handoffCalls.some((args) => args[0] === 'issue' && args[1] === 'view' && args[2] === '315'));
  assert.ok(handoffCalls.some((args) => args[0] === 'issue' && args[1] === 'view' && args[2] === '313'));
  assert.ok(ghFetchCalls.some((args) => args[0] === 'api'));
  assert.equal(closeCalls[0].repository, 'svelderrainruiz/compare-vi-cli-action');
  assert.equal(closeCalls[0].issueNumber, 315);
});

test('comparevi execution still closes the fork mirror when next-issue selection fails', async () => {
  const closeCalls = [];
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'svelderrainruiz/compare-vi-cli-action'
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot: '/tmp/repo',
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-1004',
        issue: 1004
      },
      artifacts: {
        standingRepository: 'svelderrainruiz/compare-vi-cli-action',
        standingIssueNumber: 315,
        mirrorOf: {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          number: 1004,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1004'
        },
        cadence: false
      }
    },
    deps: {
      listRepoOpenIssuesFn: async () => {
        throw new Error('detail hydration failed');
      },
      closeIssueFn: async (payload) => {
        closeCalls.push(payload);
      }
    }
  });

  assert.equal(execution.status, 'blocked');
  assert.equal(execution.outcome, 'mirror-handoff-blocked');
  assert.equal(execution.stopLoop, false);
  assert.equal(execution.details.blockerClass, 'helper');
  assert.equal(execution.details.nextWakeCondition, 'next-standing-selection-succeeds');
  assert.match(execution.details.standingSelectionWarning, /detail hydration failed/i);
  assert.equal(closeCalls.length, 0);
});

test('comparevi execution reports handoff apply failures separately from selection failures', async () => {
  const issueLabels = new Map([
    [315, ['fork-standing-priority']],
    [313, []]
  ]);
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'svelderrainruiz/compare-vi-cli-action'
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot: '/tmp/repo',
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-1004',
        issue: 1004
      },
      artifacts: {
        standingRepository: 'svelderrainruiz/compare-vi-cli-action',
        standingIssueNumber: 315,
        mirrorOf: {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          number: 1004,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1004'
        },
        cadence: false
      }
    },
    deps: {
      listRepoOpenIssuesFn: async () => [
        {
          number: 315,
          title: '[P1] Current mirror',
          body: 'body',
          labels: [{ name: 'fork-standing-priority' }],
          createdAt: '2026-03-10T00:00:00Z'
        },
        {
          number: 313,
          title: '[P1] Next development issue',
          body: 'body',
          labels: [],
          createdAt: '2026-03-09T00:00:00Z'
        }
      ],
      handoffGhRunner: (args) => {
        if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
          if (args.includes('fork-standing-priority')) {
            return JSON.stringify([{ number: 315, labels: [{ name: 'fork-standing-priority' }] }]);
          }
          return '[]';
        }
        if (args[0] === 'issue' && args[1] === 'view') {
          const issueNumber = Number(args[2]);
          return JSON.stringify({
            number: issueNumber,
            labels: (issueLabels.get(issueNumber) ?? []).map((name) => ({ name }))
          });
        }
        return '';
      },
      patchIssueLabelsFn: (_repoRoot, _repoSlug, issueNumber, labels) => {
        issueLabels.set(Number(issueNumber), Array.from(labels));
      },
      handoffSyncFn: async () => {
        throw new Error('sync failed after label mutation');
      }
    }
  });

  assert.equal(execution.status, 'blocked');
  assert.equal(execution.outcome, 'mirror-handoff-apply-blocked');
  assert.equal(execution.stopLoop, false);
  assert.equal(execution.details.blockerClass, 'helperbug');
  assert.equal(execution.details.nextWakeCondition, 'handoff-apply-recovery');
  assert.equal(execution.details.nextStandingIssueNumber, 313);
  assert.match(execution.reason, /sync failed after label mutation/i);
  assert.deepEqual(issueLabels.get(313), ['fork-standing-priority']);
});

test('comparevi execution stops when the standing issue is cadence-only work', async () => {
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'svelderrainruiz/compare-vi-cli-action'
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot: '/tmp/repo',
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-299',
        issue: 299
      },
      artifacts: {
        standingRepository: 'svelderrainruiz/compare-vi-cli-action',
        standingIssueNumber: 299,
        cadence: true
      }
    },
    deps: {}
  });

  assert.equal(execution.status, 'completed');
  assert.equal(execution.outcome, 'cadence-only');
  assert.equal(execution.stopLoop, true);
});

test('comparevi execution derives standing context from explicit lane metadata when scheduler artifacts are missing', async () => {
  const handoffCalls = [];
  const closeCalls = [];
  const fetchCalls = [];
  const issueLabels = new Map([
    [315, ['fork-standing-priority']],
    [313, []]
  ]);
  const execution = await compareviRuntimeTest.executeCompareviTurn({
    options: {
      repo: 'svelderrainruiz/compare-vi-cli-action',
      issue: 315
    },
    env: {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repoRoot: '/tmp/repo',
    schedulerDecision: {
      activeLane: {
        laneId: 'personal-1004',
        issue: 315,
        forkRemote: 'personal',
        branch: 'issue/personal-1004-runtime-worker-flow'
      }
    },
    deps: {
      ghIssueFetcher: async ({ number, slug }) => {
        fetchCalls.push({ number, slug });
        return {
          number: 315,
          title: '[P1] Fork mirror for upstream issue #1004',
          state: 'open',
          updatedAt: '2026-03-10T00:00:00Z',
          html_url: 'https://github.com/svelderrainruiz/compare-vi-cli-action/issues/315',
          url: 'https://api.github.com/repos/svelderrainruiz/compare-vi-cli-action/issues/315',
          labels: [{ name: 'fork-standing-priority' }],
          assignees: [],
          milestone: null,
          comments: 0,
          body:
            '<!-- upstream-issue-url: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1004 -->\n\nBody'
        };
      },
      restIssueFetcher: async () => null,
      listRepoOpenIssuesFn: async () => [
        {
          number: 315,
          title: '[P1] Current mirror',
          body: 'body',
          labels: [{ name: 'fork-standing-priority' }],
          createdAt: '2026-03-10T00:00:00Z'
        },
        {
          number: 313,
          title: '[P1] Next development issue',
          body: 'body',
          labels: [],
          createdAt: '2026-03-09T00:00:00Z'
        }
      ],
      handoffGhRunner: (args) => {
        handoffCalls.push(args);
        if (args[0] === 'issue' && args[1] === 'edit') {
          const issueNumber = Number(args[2]);
          const labels = new Set(issueLabels.get(issueNumber) ?? []);
          const addIndex = args.indexOf('--add-label');
          if (addIndex >= 0) {
            labels.add(args[addIndex + 1]);
          }
          const removeIndex = args.indexOf('--remove-label');
          if (removeIndex >= 0) {
            labels.delete(args[removeIndex + 1]);
          }
          issueLabels.set(issueNumber, Array.from(labels));
          return '';
        }
        if (args[0] === 'issue' && args[1] === 'view') {
          const issueNumber = Number(args[2]);
          return JSON.stringify({
            number: issueNumber,
            labels: (issueLabels.get(issueNumber) ?? []).map((name) => ({ name }))
          });
        }
        if (args[0] === 'issue' && args[1] === 'list' && args.includes('--label')) {
          if (args.includes('fork-standing-priority')) {
            return JSON.stringify([{ number: 315, labels: [{ name: 'fork-standing-priority' }] }]);
          }
          return '[]';
        }
        return '';
      },
      handoffSyncFn: async () => {},
      patchIssueLabelsFn: (_repoRoot, _repoSlug, issueNumber, labels) => {
        issueLabels.set(Number(issueNumber), Array.from(labels));
      },
      closeIssueFn: async (payload) => {
        closeCalls.push(payload);
      }
    }
  });

  assert.equal(execution.outcome, 'mirror-closed-advanced');
  assert.equal(execution.details.standingIssueNumber, 315);
  assert.ok(fetchCalls.length >= 1);
  assert.deepEqual(issueLabels.get(315), []);
  assert.deepEqual(issueLabels.get(313), ['fork-standing-priority']);
  assert.ok(handoffCalls.some((args) => args[0] === 'issue' && args[1] === 'view' && args[2] === '315'));
  assert.ok(handoffCalls.some((args) => args[0] === 'issue' && args[1] === 'view' && args[2] === '313'));
  assert.equal(closeCalls[0].issueNumber, 315);
});

test('comparevi cadence detection tolerates compact cadence markers', () => {
  assert.equal(
    compareviRuntimeTest.isCadenceAlertIssue('Maintenance queue', '<!--cadence-check:package-staleness -->'),
    true
  );
  assert.equal(
    compareviRuntimeTest.isCadenceAlertIssue('Maintenance queue', '<!--  cadence-check:package-staleness -->'),
    true
  );
});

test('comparevi issue row parser throws clear diagnostics for malformed JSON', () => {
  assert.throws(
    () =>
      compareviRuntimeTest.parseIssueRows('warning: noisy output\nnot-json', {
        source: 'gh issue list --repo example/repo --json number,title'
      }),
    /Unable to parse issue rows from gh issue list --repo example\/repo --json number,title/
  );
});
