#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRuntimeAdapter } from '../index.mjs';
import { parseObserverArgs, runRuntimeObserverLoop } from '../observer.mjs';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

function makeAdapter(repoRoot, calls) {
  return createRuntimeAdapter({
    name: 'test-adapter',
    resolveRepoRoot: () => repoRoot,
    resolveOwner: () => 'agent@example',
    resolveRepository: () => 'example/repo',
    prepareWorker: async ({ schedulerDecision }) => ({
      laneId: schedulerDecision.activeLane?.laneId,
      checkoutRoot: path.join(repoRoot, '.runtime-worktrees', 'example-repo'),
      checkoutPath: path.join(repoRoot, '.runtime-worktrees', 'example-repo', schedulerDecision.activeLane?.laneId || 'lane'),
      status: 'created',
      ref: 'upstream/develop',
      source: 'test-adapter'
    }),
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
    '3'
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
        assert.equal(ms, 0);
      }
    }
  );

  const heartbeat = await readJson(path.join(runtimeDir, 'observer-heartbeat.json'));
  const schedulerDecision = await readJson(path.join(runtimeDir, 'scheduler-decision.json'));
  const schedulerHistory = await readdir(path.join(runtimeDir, 'scheduler-decisions'));
  const workerCheckout = await readJson(path.join(runtimeDir, 'worker-checkout.json'));
  const workerHistory = await readdir(path.join(runtimeDir, 'workers'));
  const state = await readJson(path.join(runtimeDir, 'runtime-state.json'));

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
  assert.equal(heartbeat.activeLane.issue, 977);
  assert.equal(heartbeat.activeLane.worker.status, 'created');
  assert.equal(state.lifecycle.cycle, 2);
  assert.equal(state.activeLane.issue, 977);
  assert.equal(state.activeLane.worker.status, 'created');
  assert.equal(result.report.lastStep.worker.status, 'created');
  assert.equal(sleepCalls, 1);
  assert.deepEqual(
    calls.map((entry) => entry.type),
    ['acquire', 'release', 'acquire', 'release']
  );
});
