#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRuntimeAdapter, parseArgs, runRuntimeSupervisor } from '../index.mjs';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

test('createRuntimeAdapter rejects missing required hooks', () => {
  assert.throws(() => createRuntimeAdapter({ name: 'broken' }), /resolveRepoRoot/i);
});

test('parseArgs preserves the generic runtime surface', () => {
  const parsed = parseArgs([
    'node',
    'runtime-harness',
    '--action',
    'step',
    '--repo',
    'example/repo',
    '--lane',
    'origin-977',
    '--issue',
    '977',
    '--lease-scope',
    'workspace'
  ]);

  assert.equal(parsed.action, 'step');
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.lane, 'origin-977');
  assert.equal(parsed.issue, 977);
  assert.equal(parsed.leaseScope, 'workspace');
});

test('runRuntimeSupervisor executes through an injected adapter', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-harness-core-'));
  const adapterCalls = [];
  const adapter = createRuntimeAdapter({
    name: 'test-adapter',
    resolveRepoRoot: () => repoRoot,
    resolveOwner: () => 'agent@example',
    resolveRepository: () => 'example/repo',
    acquireLease: async (leaseOptions) => {
      adapterCalls.push({ type: 'acquire', leaseOptions });
      return {
        action: 'acquire',
        status: 'acquired',
        scope: leaseOptions.scope,
        owner: leaseOptions.owner,
        checkedAt: '2026-03-10T15:00:00.000Z',
        lease: {
          leaseId: 'lease-core-1',
          owner: leaseOptions.owner
        }
      };
    },
    releaseLease: async (leaseOptions) => {
      adapterCalls.push({ type: 'release', leaseOptions });
      return {
        action: 'release',
        status: 'released',
        scope: leaseOptions.scope,
        owner: leaseOptions.owner,
        checkedAt: '2026-03-10T15:00:05.000Z',
        lease: {
          leaseId: leaseOptions.leaseId,
          owner: leaseOptions.owner
        }
      };
    }
  });

  const result = await runRuntimeSupervisor(
    {
      action: 'step',
      runtimeDir: 'tests/results/_agent/runtime',
      lane: 'origin-977',
      issue: 977,
      epic: 967,
      forkRemote: 'origin',
      branch: 'issue/origin-977-fork-policy-portability',
      worker: {
        laneId: 'origin-977',
        checkoutPath: path.join(repoRoot, 'workers', 'origin-977'),
        checkoutRoot: path.join(repoRoot, 'workers'),
        status: 'created',
        ref: 'upstream/develop'
      },
      workerReady: {
        laneId: 'origin-977',
        checkoutPath: path.join(repoRoot, 'workers', 'origin-977'),
        status: 'ready',
        bootstrapCommand: ['pwsh', '-NoLogo', '-NoProfile', '-File', 'tools/priority/bootstrap.ps1']
      },
      workerBranch: {
        laneId: 'origin-977',
        checkoutPath: path.join(repoRoot, 'workers', 'origin-977'),
        branch: 'issue/origin-977-fork-policy-portability',
        forkRemote: 'origin',
        status: 'attached',
        trackingRef: 'origin/issue/origin-977-fork-policy-portability'
      },
      taskPacket: {
        schema: 'priority/runtime-worker-task-packet@v1',
        generatedAt: '2026-03-10T15:00:00.000Z',
        cycle: 1,
        laneId: 'origin-977',
        status: 'ready',
        source: 'test-adapter',
        objective: {
          summary: 'Advance issue #977',
          source: 'test-adapter'
        },
        branch: {
          name: 'issue/origin-977-fork-policy-portability',
          forkRemote: 'origin',
          status: 'attached',
          trackingRef: 'origin/issue/origin-977-fork-policy-portability',
          checkoutPath: path.join(repoRoot, 'workers', 'origin-977')
        },
        pullRequest: {
          url: 'https://example.test/pr/7',
          status: 'linked'
        },
        checks: {
          status: 'blocked',
          blockerClass: 'ci'
        },
        helperSurface: {
          preferred: ['node tools/npm/run-script.mjs priority:pr'],
          fallbacks: ['gh pr create --body-file <path>']
        },
        recentEvents: [],
        evidence: {},
        artifacts: {
          latestPath: path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'task-packet.json'),
          historyPath: path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'task-packets', '2026-03-10T15-00-00-000Z-0001.json')
        }
      },
      blockerClass: 'ci',
      reason: 'hosted checks are red'
    },
    {
      now: new Date('2026-03-10T15:00:00.000Z'),
      adapter
    }
  );

  const state = await readJson(path.join(repoRoot, 'tests', 'results', '_agent', 'runtime', 'runtime-state.json'));
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.runtimeAdapter, 'test-adapter');
  assert.equal(state.runtimeAdapter, 'test-adapter');
  assert.equal(state.activeLane.worker.checkoutPath, path.join(repoRoot, 'workers', 'origin-977'));
  assert.equal(result.report.worker.status, 'created');
  assert.equal(state.activeLane.workerReady.status, 'ready');
  assert.equal(result.report.workerReady.status, 'ready');
  assert.equal(state.activeLane.workerBranch.status, 'attached');
  assert.equal(result.report.workerBranch.branch, 'issue/origin-977-fork-policy-portability');
  assert.equal(state.activeLane.taskPacket.objective.summary, 'Advance issue #977');
  assert.equal(result.report.taskPacket.status, 'ready');
  assert.deepEqual(
    adapterCalls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});
