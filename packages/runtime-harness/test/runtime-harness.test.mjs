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
  assert.deepEqual(
    adapterCalls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});
