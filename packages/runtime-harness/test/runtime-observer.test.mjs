#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { access, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRuntimeAdapter } from '../index.mjs';
import { DEFAULT_POLL_INTERVAL_SECONDS, parseObserverArgs, runRuntimeObserverLoop } from '../observer.mjs';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function pathExists(filePath) {
  try {
    await access(filePath);
    return true;
  } catch (error) {
    if (error?.code === 'ENOENT') return false;
    throw error;
  }
}

function makeAdapter(repoRoot, calls, options = {}) {
  const bootstrapMode = options.bootstrapMode ?? 'ready';
  const plannerMode = options.plannerMode ?? 'manual';
  const activateMode = options.activateMode ?? 'attached';
  const executeMode = options.executeMode ?? 'none';
  const executionDetails = options.executionDetails ?? {};
  return createRuntimeAdapter({
    name: 'test-adapter',
    resolveRepoRoot: () => repoRoot,
    resolveOwner: () => 'agent@example',
    resolveRepository: () => 'example/repo',
    planStep: async ({ explicitStepOptions }) => {
      if (plannerMode === 'idle') {
        return {
          source: 'test-planner',
          outcome: 'idle',
          reason: 'queue empty'
        };
      }
      if (plannerMode === 'blocked') {
        return {
          source: 'test-planner',
          outcome: 'blocked',
          reason: 'review blocked on current lane',
          stepOptions: explicitStepOptions
        };
      }
      return {
        source: 'manual',
        outcome: 'selected',
        reason: 'using explicit observer lane input',
        stepOptions: explicitStepOptions
      };
    },
    prepareWorker: async ({ schedulerDecision }) => ({
      laneId: schedulerDecision.activeLane?.laneId,
      checkoutRoot: path.join(repoRoot, '.runtime-worktrees', 'example-repo'),
      checkoutPath: path.join(repoRoot, '.runtime-worktrees', 'example-repo', schedulerDecision.activeLane?.laneId || 'lane'),
      status: 'created',
      ref: 'upstream/develop',
      source: 'test-adapter'
    }),
    bootstrapWorker: async ({ preparedWorker, schedulerDecision }) => {
      if (bootstrapMode === 'throw') {
        const error = new Error('bootstrap exploded');
        error.stderr = 'mocked stderr';
        throw error;
      }
      if (bootstrapMode === 'blocked') {
        return {
          laneId: schedulerDecision.activeLane?.laneId,
          checkoutPath: preparedWorker.checkoutPath,
          status: 'blocked',
          source: 'test-adapter',
          reason: 'bootstrap blocked',
          bootstrapCommand: ['pwsh', '-NoLogo', '-NoProfile', '-File', 'tools/priority/bootstrap.ps1'],
          bootstrapExitCode: 1
        };
      }
      return {
        laneId: schedulerDecision.activeLane?.laneId,
        checkoutPath: preparedWorker.checkoutPath,
        status: 'ready',
        source: 'test-adapter',
        bootstrapCommand: ['pwsh', '-NoLogo', '-NoProfile', '-File', 'tools/priority/bootstrap.ps1']
      };
    },
    activateWorker: async ({ workerReady, schedulerDecision }) => {
      if (activateMode === 'blocked') {
        return {
          laneId: schedulerDecision.activeLane?.laneId,
          checkoutPath: workerReady.checkoutPath,
          branch: schedulerDecision.activeLane?.branch,
          forkRemote: schedulerDecision.activeLane?.forkRemote,
          status: 'blocked',
          source: 'test-adapter',
          reason: 'activation blocked'
        };
      }
      return {
        laneId: schedulerDecision.activeLane?.laneId,
        checkoutPath: workerReady.checkoutPath,
        branch: schedulerDecision.activeLane?.branch,
        forkRemote: schedulerDecision.activeLane?.forkRemote,
        status: 'attached',
        source: 'test-adapter',
        trackingRef: `${schedulerDecision.activeLane?.forkRemote}/${schedulerDecision.activeLane?.branch}`,
        fetchedRemotes: ['upstream', 'origin']
      };
    },
    buildTaskPacket: async ({ schedulerDecision, cycle, recentEvents }) => ({
      source: 'test-adapter',
      objective: {
        summary: schedulerDecision.activeLane?.issue
          ? `Execute issue #${schedulerDecision.activeLane.issue}`
          : 'Observe idle runtime state',
        source: 'test-adapter'
      },
      helperSurface: {
        preferred: ['node tools/npm/run-script.mjs priority:pr'],
        fallbacks: ['gh pr create --body-file <path>']
      },
      evidence: {
        adapter: {
          cycle,
          recentEventCount: recentEvents.length
        }
      }
    }),
    executeTurn:
      executeMode === 'none'
        ? null
        : async ({ schedulerDecision }) => {
            if (executeMode === 'throw') {
              throw new Error('execution hook exploded');
            }
            if (executeMode === 'blocked') {
              return {
                status: 'blocked',
                outcome: 'execution-blocked',
                reason: 'execution hook blocked the lane'
              };
            }
            return {
              status: 'completed',
              outcome: executeMode === 'stop' ? 'execution-stop' : 'execution-completed',
              stopLoop: executeMode === 'stop',
              details: {
                issue: schedulerDecision.activeLane?.issue ?? null,
                ...(executionDetails && typeof executionDetails === 'object' ? executionDetails : {})
              }
            };
          },
    acquireLease: async (leaseOptions) => {
      calls.push({ type: 'acquire', leaseOptions });
      return {
        action: 'acquire',
        status: 'acquired',
        scope: leaseOptions.scope,
        owner: leaseOptions.owner,
        checkedAt: '2026-03-10T16:00:00.000Z',
        lease: {
          leaseId: `lease-${calls.length}`,
          owner: leaseOptions.owner
        }
      };
    },
    releaseLease: async (leaseOptions) => {
      calls.push({ type: 'release', leaseOptions });
      return {
        action: 'release',
        status: 'released',
        scope: leaseOptions.scope,
        owner: leaseOptions.owner,
        checkedAt: '2026-03-10T16:00:05.000Z',
        lease: {
          leaseId: leaseOptions.leaseId,
          owner: leaseOptions.owner
        }
      };
    }
  });
}

test('parseObserverArgs preserves daemon loop options', () => {
  const parsed = parseObserverArgs([
    'node',
    'runtime-daemon',
    '--repo',
    'example/repo',
    '--runtime-dir',
    'custom-runtime',
    '--heartbeat-path',
    'custom-runtime/heartbeat.json',
    '--scheduler-decision-path',
    'custom-runtime/scheduler-decision.json',
    '--scheduler-decisions-dir',
    'custom-runtime/scheduler-decisions',
    '--lane',
    'origin-977',
    '--issue',
    '977',
    '--epic',
    '967',
    '--fork-remote',
    'origin',
    '--branch',
    'issue/origin-977-fork-policy-portability',
    '--blocker-class',
    'ci',
    '--poll-interval-seconds',
    '15',
    '--max-cycles',
    '3',
    '--stop-on-idle',
    '--execute-turn'
  ]);

  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.runtimeDir, 'custom-runtime');
  assert.equal(parsed.heartbeatPath, 'custom-runtime/heartbeat.json');
  assert.equal(parsed.schedulerDecisionPath, 'custom-runtime/scheduler-decision.json');
  assert.equal(parsed.schedulerDecisionsDir, 'custom-runtime/scheduler-decisions');
  assert.equal(parsed.lane, 'origin-977');
  assert.equal(parsed.issue, 977);
  assert.equal(parsed.epic, 967);
  assert.equal(parsed.forkRemote, 'origin');
  assert.equal(parsed.branch, 'issue/origin-977-fork-policy-portability');
  assert.equal(parsed.blockerClass, 'ci');
  assert.equal(parsed.pollIntervalSeconds, 15);
  assert.equal(parsed.maxCycles, 3);
  assert.equal(parsed.stopOnIdle, true);
  assert.equal(parsed.executeTurn, true);
});

test('runRuntimeObserverLoop blocks on non-linux platforms', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-blocked-'));
  const calls = [];
  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir: 'tests/results/_agent/runtime'
    },
    {
      platform: 'win32',
      adapter: makeAdapter(repoRoot, calls)
    }
  );

  assert.equal(result.exitCode, 2);
  assert.equal(result.report.status, 'blocked');
  assert.equal(result.report.outcome, 'linux-only');
  assert.equal(result.report.runtimeAdapter, 'test-adapter');
  assert.deepEqual(calls, []);
});

test('runRuntimeObserverLoop writes heartbeat and state across bounded linux cycles', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-linux-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-root-'));
  const calls = [];
  let sleepCalls = 0;
  let tick = 0;
  const nowFactory = () => new Date(Date.UTC(2026, 2, 10, 16, 0, tick++));

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-977',
      issue: 977,
      epic: 967,
      forkRemote: 'origin',
      branch: 'issue/origin-977-fork-policy-portability',
      prUrl: 'https://example.test/pr/7',
      blockerClass: 'ci',
      reason: 'hosted checks are red',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 2
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls),
      nowFactory,
      sleepFn: async (ms) => {
        sleepCalls += 1;
        assert.equal(ms, DEFAULT_POLL_INTERVAL_SECONDS * 1000);
      }
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));
  const schedulerDecision = await readJson(path.join(runtimeDir, 'scheduler-decision.json'));
  const schedulerHistory = await readdir(path.join(runtimeDir, 'scheduler-decisions'));
  const workerCheckout = await readJson(path.join(runtimeDir, 'worker-checkout.json'));
  const workerHistory = await readdir(path.join(runtimeDir, 'workers'));
  const workerReady = await readJson(path.join(runtimeDir, 'worker-ready.json'));
  const workerReadyHistory = await readdir(path.join(runtimeDir, 'workers-ready'));
  const workerBranch = await readJson(path.join(runtimeDir, 'worker-branch.json'));
  const workerBranchHistory = await readdir(path.join(runtimeDir, 'workers-branch'));
  const taskPacket = await readJson(path.join(runtimeDir, 'task-packet.json'));
  const taskPacketHistory = await readdir(path.join(runtimeDir, 'task-packets'));
  const state = await readJson(path.join(runtimeDir, 'delivery-agent-state.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.outcome, 'max-cycles-reached');
  assert.equal(result.report.cyclesCompleted, 2);
  assert.equal(result.report.lastDecision.outcome, 'selected');
  assert.equal(result.report.lastDecision.source, 'manual');
  assert.equal(result.report.lastStep.outcome, 'lane-tracked');
  assert.equal(heartbeat.schema, 'priority/runtime-observer-heartbeat@v1');
  assert.equal(heartbeat.cyclesCompleted, 2);
  assert.equal(heartbeat.outcome, 'lane-tracked');
  assert.equal(heartbeat.schedulerDecision.source, 'manual');
  assert.equal(heartbeat.schedulerDecision.activeLane.issue, 977);
  assert.equal(schedulerDecision.schema, 'priority/runtime-scheduler-decision@v1');
  assert.equal(schedulerDecision.outcome, 'selected');
  assert.equal(schedulerDecision.stepOptions.issue, 977);
  assert.equal(schedulerHistory.length, 2);
  assert.equal(workerCheckout.schema, 'priority/runtime-worker-checkout@v1');
  assert.equal(workerCheckout.status, 'created');
  assert.equal(workerHistory.length, 1);
  assert.equal(workerReady.schema, 'priority/runtime-worker-ready@v1');
  assert.equal(workerReady.status, 'ready');
  assert.equal(workerReadyHistory.length, 1);
  assert.equal(workerBranch.schema, 'priority/runtime-worker-branch@v1');
  assert.equal(workerBranch.status, 'attached');
  assert.equal(workerBranch.branch, 'issue/origin-977-fork-policy-portability');
  assert.equal(workerBranchHistory.length, 1);
  assert.equal(taskPacket.schema, 'priority/runtime-worker-task-packet@v1');
  assert.equal(taskPacket.objective.summary, 'Execute issue #977');
  assert.equal(taskPacket.helperSurface.preferred[0], 'node tools/npm/run-script.mjs priority:pr');
  assert.equal(taskPacket.recentEvents.length, 1);
  assert.equal(taskPacketHistory.length, 2);
  assert.equal(heartbeat.activeLane.issue, 977);
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(heartbeat.activeLane.workerReady.status, 'ready');
  assert.equal(heartbeat.activeLane.workerBranch.status, 'attached');
  assert.equal(heartbeat.activeLane.taskPacket.objective.summary, 'Execute issue #977');
  assert.equal(heartbeat.artifacts.taskPacketPath, path.join(runtimeDir, 'task-packet.json'));
  assert.equal(state.lifecycle.cycle, 2);
  assert.equal(state.activeLane.issue, 977);
  assert.equal(state.activeLane.worker.status, 'created');
  assert.equal(state.activeLane.workerReady.status, 'ready');
  assert.equal(state.activeLane.workerBranch.status, 'attached');
  assert.equal(state.activeLane.taskPacket.objective.summary, 'Execute issue #977');
  assert.equal(result.report.lastStep.worker.status, 'created');
  assert.equal(result.report.lastStep.workerReady.status, 'ready');
  assert.equal(result.report.lastStep.workerBranch.status, 'attached');
  assert.equal(result.report.lastStep.taskPacket.objective.summary, 'Execute issue #977');
  assert.equal(sleepCalls, 1);
  assert.deepEqual(
    calls.map((entry) => entry.type),
    ['acquire', 'release', 'acquire', 'release']
  );
});

test('runRuntimeObserverLoop honors a shorter execution poll hint for near-term wake conditions', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-poll-hint-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-poll-hint-root-'));
  const calls = [];
  const sleepCalls = [];

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1015',
      issue: 1015,
      forkRemote: 'origin',
      branch: 'issue/origin-1015-copilot-watch',
      owner: 'agent@example',
      pollIntervalSeconds: 60,
      maxCycles: 2,
      executeTurn: true
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, {
        executeMode: 'complete',
        executionDetails: {
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'copilot-review-workflow-completed',
          pollIntervalSecondsHint: 10
        }
      }),
      sleepFn: async (ms) => {
        sleepCalls.push(ms);
      }
    }
  );

  assert.equal(result.exitCode, 0);
  assert.deepEqual(sleepCalls, [10000]);
});

test('runRuntimeObserverLoop clamps non-positive configured poll intervals to a safe default', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-poll-default-clamp-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-poll-default-clamp-root-'));
  const calls = [];
  const sleepCalls = [];

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1015',
      issue: 1015,
      forkRemote: 'origin',
      branch: 'issue/origin-1015-copilot-watch',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 2,
      executeTurn: true
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, {
        executeMode: 'complete',
        executionDetails: {
          laneLifecycle: 'waiting-review',
          blockerClass: 'review',
          retryable: true,
          nextWakeCondition: 'review-disposition-updated'
        }
      }),
      sleepFn: async (ms) => {
        sleepCalls.push(ms);
      }
    }
  );

  assert.equal(result.exitCode, 0);
  assert.deepEqual(sleepCalls, [DEFAULT_POLL_INTERVAL_SECONDS * 1000]);
});

test('runRuntimeObserverLoop emits an idle task packet when the planner returns idle', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-idle-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-idle-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { plannerMode: 'idle' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 15, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when maxCycles=1');
      }
    }
  );

  const taskPacket = await readJson(path.join(runtimeDir, 'task-packet.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.lastDecision.outcome, 'idle');
  assert.equal(result.report.lastStep.outcome, 'idle');
  assert.equal(taskPacket.status, 'idle');
  assert.equal(taskPacket.objective.summary, 'Observe idle runtime state');
  assert.equal(taskPacket.laneId, null);
  assert.equal(taskPacket.evidence.adapter.cycle, 1);
});

test('runRuntimeObserverLoop stops cleanly on idle when stopOnIdle is enabled', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-idle-stop-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-idle-stop-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 0,
      stopOnIdle: true
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { plannerMode: 'idle' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 16, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when stopOnIdle is enabled');
      }
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.outcome, 'idle-stop');
  assert.equal(result.report.lastStep.outcome, 'idle');
  assert.equal(heartbeat.outcome, 'idle-stop');
});

test('runRuntimeObserverLoop emits a blocked task packet when the planner blocks the lane', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-task-blocked-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-task-blocked-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1002',
      issue: 1002,
      epic: 958,
      forkRemote: 'personal',
      branch: 'issue/personal-1002-runtime-daemon-task-packets',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { plannerMode: 'blocked' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 20, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when planner blocks');
      }
    }
  );

  const taskPacket = await readJson(path.join(runtimeDir, 'task-packet.json'));
  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 12);
  assert.equal(result.report.outcome, 'scheduler-blocked');
  assert.equal(taskPacket.status, 'blocked');
  assert.equal(taskPacket.laneId, 'origin-1002');
  assert.equal(taskPacket.objective.summary, 'Execute issue #1002');
  assert.equal(heartbeat.artifacts.taskPacketPath, path.join(runtimeDir, 'task-packet.json'));
  assert.equal(heartbeat.activeLane.taskPacket.objective.summary, 'Execute issue #1002');
});

test('runRuntimeObserverLoop records worker-ready-blocked when bootstrap returns a blocked result', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-bootstrap-blocked-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-bootstrap-blocked-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-997',
      issue: 997,
      forkRemote: 'origin',
      branch: 'issue/origin-997-runtime-worker-ready-state',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { bootstrapMode: 'blocked' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 30, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when bootstrap is blocked');
      }
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));
  const workerReady = await readJson(path.join(runtimeDir, 'worker-ready.json'));

  assert.equal(result.exitCode, 14);
  assert.equal(result.report.status, 'blocked');
  assert.equal(result.report.outcome, 'worker-ready-blocked');
  assert.equal(result.report.lastStep.workerReady.status, 'blocked');
  assert.equal(heartbeat.outcome, 'worker-ready-blocked');
  assert.equal(heartbeat.activeLane.workerReady.status, 'blocked');
  assert.equal(workerReady.status, 'blocked');
  assert.deepEqual(calls, []);
});

test('runRuntimeObserverLoop still writes a task packet when worker branch activation blocks', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-branch-blocked-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-branch-blocked-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1005',
      issue: 1005,
      epic: 958,
      forkRemote: 'origin',
      branch: 'issue/origin-1005-runtime-task-packets',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { activateMode: 'blocked' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 35, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when worker branch activation is blocked');
      }
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));
  const workerBranch = await readJson(path.join(runtimeDir, 'worker-branch.json'));
  const taskPacket = await readJson(path.join(runtimeDir, 'task-packet.json'));
  const taskPacketHistory = await readdir(path.join(runtimeDir, 'task-packets'));

  assert.equal(result.exitCode, 15);
  assert.equal(result.report.status, 'blocked');
  assert.equal(result.report.outcome, 'worker-branch-blocked');
  assert.equal(result.report.lastStep.workerBranch.status, 'blocked');
  assert.equal(taskPacket.status, 'blocked');
  assert.equal(taskPacket.objective.summary, 'Execute issue #1005');
  assert.equal(taskPacketHistory.length, 1);
  assert.equal(heartbeat.outcome, 'worker-branch-blocked');
  assert.equal(heartbeat.activeLane.workerBranch.status, 'blocked');
  assert.equal(heartbeat.activeLane.taskPacket.objective.summary, 'Execute issue #1005');
  assert.equal(heartbeat.artifacts.taskPacketPath, path.join(runtimeDir, 'task-packet.json'));
  assert.equal(workerBranch.status, 'blocked');
});

test('runRuntimeObserverLoop writes an execution receipt when executeTurn is enabled', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-execution-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-execution-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1005',
      issue: 1005,
      forkRemote: 'origin',
      branch: 'issue/origin-1005-runtime-execution',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1,
      executeTurn: true
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { executeMode: 'complete' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 40, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when maxCycles=1');
      }
    }
  );

  const executionReceipt = await readJson(path.join(runtimeDir, 'execution-receipt.json'));
  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.lastStep.execution.outcome, 'execution-completed');
  assert.equal(executionReceipt.outcome, 'execution-completed');
  assert.equal(heartbeat.activeLane.execution.outcome, 'execution-completed');
});

test('runRuntimeObserverLoop persists heartbeat and blocked receipt when executeTurn throws', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-execution-throw-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-execution-throw-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1007',
      issue: 1007,
      forkRemote: 'origin',
      branch: 'issue/origin-1007-runtime-execution-throw',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1,
      executeTurn: true
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { executeMode: 'throw' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 40, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when execution fails');
      }
    }
  );

  const executionReceipt = await readJson(path.join(runtimeDir, 'execution-receipt.json'));
  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));

  assert.equal(result.exitCode, 16);
  assert.equal(result.report.status, 'blocked');
  assert.equal(result.report.outcome, 'execution-failed');
  assert.equal(result.report.lastStep.execution.outcome, 'execution-failed');
  assert.equal(executionReceipt.status, 'blocked');
  assert.equal(executionReceipt.outcome, 'execution-failed');
  assert.equal(heartbeat.outcome, 'execution-failed');
  assert.equal(heartbeat.activeLane.execution.outcome, 'execution-failed');
});

test('runRuntimeObserverLoop stops after execution hook requests it', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-execution-stop-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-execution-stop-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1006',
      issue: 1006,
      forkRemote: 'origin',
      branch: 'issue/origin-1006-runtime-execution-stop',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 0,
      executeTurn: true
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { executeMode: 'stop' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 41, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when execution stop is requested');
      }
    }
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.outcome, 'execution-stop');
});

test('runRuntimeObserverLoop records worker-bootstrap-failed heartbeat when bootstrap throws', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-bootstrap-failed-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-bootstrap-failed-root-'));
  const calls = [];
  let tick = 0;

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-997',
      issue: 997,
      forkRemote: 'origin',
      branch: 'issue/origin-997-runtime-worker-ready-state',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls, { bootstrapMode: 'throw' }),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 45, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when bootstrap throws');
      }
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));
  const workerCheckout = await readJson(path.join(runtimeDir, 'worker-checkout.json'));
  const workerReadyPath = path.join(runtimeDir, 'worker-ready.json');

  assert.equal(result.exitCode, 14);
  assert.equal(result.report.status, 'blocked');
  assert.equal(result.report.outcome, 'worker-bootstrap-failed');
  assert.equal(result.report.lastStep.worker.status, 'created');
  assert.equal(result.report.lastStep.workerReady, null);
  assert.equal(heartbeat.outcome, 'worker-bootstrap-failed');
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(heartbeat.artifacts.workerCheckoutPath, path.join(runtimeDir, 'worker-checkout.json'));
  assert.equal(heartbeat.artifacts.workerReadyPath, null);
  assert.equal(workerCheckout.status, 'created');
  assert.equal(await pathExists(workerReadyPath), false);
  assert.deepEqual(calls, []);
});

test('runRuntimeObserverLoop reads only the recent valid event tail', async () => {
  const runtimeDir = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-recent-events-'));
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-observer-recent-events-root-'));
  const calls = [];
  let tick = 0;
  const eventsPath = path.join(runtimeDir, 'runtime-events.ndjson');
  const largePayload = 'x'.repeat(256);
  const lines = [];
  for (let index = 0; index < 300; index += 1) {
    lines.push(JSON.stringify({
      sequence: index,
      kind: 'info',
      message: `event-${index}`,
      payload: largePayload
    }));
  }
  lines.splice(10, 0, '{"sequence": "bad"');
  await writeFile(eventsPath, `${lines.join('\n')}\n`, 'utf8');

  const result = await runRuntimeObserverLoop(
    {
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-1006',
      issue: 1006,
      epic: 958,
      forkRemote: 'origin',
      branch: 'issue/origin-1006-runtime-events-tail',
      owner: 'agent@example',
      pollIntervalSeconds: 0,
      maxCycles: 1
    },
    {
      platform: 'linux',
      adapter: makeAdapter(repoRoot, calls),
      nowFactory: () => new Date(Date.UTC(2026, 2, 10, 16, 45, tick++)),
      sleepFn: async () => {
        throw new Error('sleep should not run when maxCycles=1');
      }
    }
  );

  const taskPacket = await readJson(path.join(runtimeDir, 'task-packet.json'));

  assert.equal(result.exitCode, 0);
  assert.deepEqual(
    taskPacket.recentEvents.map((event) => event.sequence),
    [295, 296, 297, 298, 299]
  );
  assert.equal(taskPacket.evidence.adapter.recentEventCount, 5);
});
