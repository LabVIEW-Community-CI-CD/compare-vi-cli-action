#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { parseArgs, runRuntimeSupervisor } from '../runtime-supervisor.mjs';

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function readNdjson(filePath) {
  const raw = await readFile(filePath, 'utf8');
  return raw
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
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
        checkedAt: '2026-03-10T00:00:00.000Z',
        lease: {
          leaseId: 'lease-1',
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
        checkedAt: '2026-03-10T00:00:05.000Z',
        lease: {
          leaseId: options.leaseId,
          owner: options.owner
        }
      };
    }
  };
}

test('parseArgs accepts runtime action, lane metadata, and lease options', () => {
  const parsed = parseArgs([
    'node',
    'runtime-supervisor.mjs',
    '--action',
    'step',
    '--repo',
    'example/repo',
    '--runtime-dir',
    'custom-runtime',
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
    '--pr-url',
    'https://example.test/pr/7',
    '--blocker-class',
    'ci',
    '--reason',
    'hosted checks are red',
    '--lease-scope',
    'workspace',
    '--lease-root',
    '.tmp/leases',
    '--owner',
    'agent@example'
  ]);

  assert.equal(parsed.action, 'step');
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.runtimeDir, 'custom-runtime');
  assert.equal(parsed.lane, 'origin-977');
  assert.equal(parsed.issue, 977);
  assert.equal(parsed.epic, 967);
  assert.equal(parsed.forkRemote, 'origin');
  assert.equal(parsed.branch, 'issue/origin-977-fork-policy-portability');
  assert.equal(parsed.prUrl, 'https://example.test/pr/7');
  assert.equal(parsed.blockerClass, 'ci');
  assert.equal(parsed.reason, 'hosted checks are red');
  assert.equal(parsed.leaseScope, 'workspace');
  assert.equal(parsed.leaseRoot, '.tmp/leases');
  assert.equal(parsed.owner, 'agent@example');
});

test('runRuntimeSupervisor step writes runtime state, lane, turn, event, and blocker artifacts', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-supervisor-'));
  const runtimeDir = 'tests/results/_agent/runtime';
  const deps = makeLeaseDeps();
  const result = await runRuntimeSupervisor(
    {
      action: 'step',
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
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T12:00:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );

  const runtimeRoot = path.join(repoRoot, runtimeDir);
  const state = await readJson(path.join(runtimeRoot, 'runtime-state.json'));
  const lane = await readJson(path.join(runtimeRoot, 'lanes', 'origin-977.json'));
  const blocker = await readJson(path.join(runtimeRoot, 'last-blocker.json'));
  const events = await readNdjson(path.join(runtimeRoot, 'runtime-events.ndjson'));
  const turnsDir = path.join(runtimeRoot, 'turns');
  const turnStats = await stat(result.report.turnPath);
  const turn = await readJson(result.report.turnPath);

  assert.equal(result.exitCode, 0);
  assert.equal(state.schema, 'priority/runtime-supervisor-state@v1');
  assert.equal(state.lifecycle.status, 'running');
  assert.equal(state.lifecycle.cycle, 1);
  assert.equal(state.lifecycle.stopRequested, false);
  assert.equal(state.activeLane.laneId, 'origin-977');
  assert.equal(state.summary.trackedLaneCount, 1);
  assert.equal(lane.issue, 977);
  assert.equal(lane.epic, 967);
  assert.equal(lane.blocker.blockerClass, 'ci');
  assert.equal(blocker.issue, 977);
  assert.equal(blocker.blockerClass, 'ci');
  assert.equal(events.length, 1);
  assert.equal(events[0].outcome, 'lane-tracked');
  assert.equal(turn.schema, 'priority/runtime-turn@v1');
  assert.equal(turn.outcome, 'lane-tracked');
  assert.equal(turn.activeLane.issue, 977);
  assert.ok(turnStats.isFile());
  assert.match(turnsDir, /turns$/);
  assert.deepEqual(
    deps.calls.map((entry) => entry.type),
    ['acquire', 'release']
  );
});

test('stop, step with stop request, and resume manage runtime control state deterministically', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'runtime-supervisor-stop-'));
  const runtimeDir = 'tests/results/_agent/runtime';
  const deps = makeLeaseDeps();

  const stopResult = await runRuntimeSupervisor(
    {
      action: 'stop',
      repo: 'example/repo',
      runtimeDir,
      reason: 'operator pause',
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T13:00:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );
  assert.equal(stopResult.exitCode, 0);

  const pausedStep = await runRuntimeSupervisor(
    {
      action: 'step',
      repo: 'example/repo',
      runtimeDir,
      lane: 'origin-978',
      issue: 978,
      forkRemote: 'personal',
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T13:05:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );
  assert.equal(pausedStep.exitCode, 0);
  assert.equal(pausedStep.report.outcome, 'stop-requested');

  const resumeResult = await runRuntimeSupervisor(
    {
      action: 'resume',
      repo: 'example/repo',
      runtimeDir,
      owner: 'agent@example'
    },
    {
      now: new Date('2026-03-10T13:10:00.000Z'),
      resolveRepoRootFn: () => repoRoot,
      ...deps
    }
  );
  assert.equal(resumeResult.exitCode, 0);

  const runtimeRoot = path.join(repoRoot, runtimeDir);
  const state = await readJson(path.join(runtimeRoot, 'runtime-state.json'));
  const events = await readNdjson(path.join(runtimeRoot, 'runtime-events.ndjson'));

  assert.equal(state.lifecycle.stopRequested, false);
  assert.equal(state.lifecycle.status, 'idle');
  assert.equal(events.map((entry) => entry.action).join(','), 'stop,step,resume');
  assert.equal(events[1].outcome, 'stop-requested');
});
