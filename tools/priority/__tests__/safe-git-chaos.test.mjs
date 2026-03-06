#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { runGitWithSafety } from '../lib/safe-git.mjs';
import { evaluateWorkspaceHealth } from '../lib/workspace-health.mjs';

const fixturePath = path.resolve('tools', 'priority', '__fixtures__', 'safe-git-chaos', 'scenarios.json');
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));

const repoRoot = path.resolve(path.sep, 'tmp', 'safe-git-chaos-repo');
const gitDir = path.join(repoRoot, '.git');
const indexPath = path.join(gitDir, 'index');

function toFsPath(relativePath) {
  return path.join(gitDir, ...String(relativePath).split('/').filter(Boolean));
}

function createDirent(name, isDirectory) {
  return {
    name,
    isDirectory: () => isDirectory,
    isFile: () => !isDirectory
  };
}

function createReaddir(lockMtimes) {
  return (dirPath, options = {}) => {
    const normalizedDir = path.normalize(dirPath);
    const prefix = normalizedDir.endsWith(path.sep) ? normalizedDir : `${normalizedDir}${path.sep}`;
    const children = new Map();

    for (const fullLockPath of lockMtimes.keys()) {
      const normalizedLock = path.normalize(fullLockPath);
      if (!normalizedLock.startsWith(prefix)) {
        continue;
      }
      const remainder = normalizedLock.slice(prefix.length);
      if (!remainder) {
        continue;
      }
      const [segment, ...rest] = remainder.split(path.sep);
      const isDirectory = rest.length > 0;
      const existing = children.get(segment);
      if (!existing || (existing === false && isDirectory)) {
        children.set(segment, isDirectory);
      }
    }

    if (!options.withFileTypes) {
      return [...children.keys()];
    }

    return [...children.entries()].map(([name, isDirectory]) => createDirent(name, Boolean(isDirectory)));
  };
}

function createScenarioState(scenario) {
  const existing = new Set([path.normalize(indexPath)]);
  const lockMtimes = new Map();
  const markerSet = new Set();
  const activePids = [...(scenario.activePids ?? [])];
  const removedLocks = [];
  const killedPids = [];
  let commandInvocations = 0;

  for (const lock of scenario.locks ?? []) {
    const lockPath = path.normalize(toFsPath(lock.path));
    existing.add(lockPath);
    lockMtimes.set(lockPath, Number(lock.mtimeMs ?? scenario.nowMs ?? 120_000));
  }

  for (const marker of scenario.markers ?? []) {
    const markerPath = path.normalize(toFsPath(marker));
    existing.add(markerPath);
    markerSet.add(markerPath);
  }

  const readdirSyncFn = createReaddir(lockMtimes);

  const common = {
    existsSyncFn: (targetPath) => existing.has(path.normalize(targetPath)),
    accessSyncFn: (targetPath) => {
      const normalized = path.normalize(targetPath);
      if (normalized !== path.normalize(indexPath)) {
        return;
      }
      if (scenario.indexWritable === false) {
        const error = new Error('EACCES');
        error.code = 'EACCES';
        throw error;
      }
    },
    readdirSyncFn,
    statSyncFn: (targetPath) => {
      const normalized = path.normalize(targetPath);
      return { mtimeMs: lockMtimes.get(normalized) ?? Number(scenario.nowMs ?? 120_000) };
    },
    nowFn: () => Number(scenario.nowMs ?? 120_000)
  };

  const healthDeps = {
    ...common,
    readFileSyncFn: () => {
      const error = new Error('ENOENT');
      error.code = 'ENOENT';
      throw error;
    }
  };

  const brokerOptions = {
    ...common,
    resolveGitDirFn: () => gitDir,
    rmSyncFn: (targetPath) => {
      const normalized = path.normalize(targetPath);
      existing.delete(normalized);
      lockMtimes.delete(normalized);
      removedLocks.push(path.relative(gitDir, normalized).split(path.sep).join('/'));
    },
    listGitProcessesFn: () => [...activePids],
    killGitProcessFn: (pid) => {
      const index = activePids.indexOf(pid);
      if (index >= 0) {
        activePids.splice(index, 1);
        killedPids.push(pid);
        return true;
      }
      return false;
    },
    spawnSyncFn: (_file, args) => {
      commandInvocations += 1;
      return { status: 0, stdout: 'ok', stderr: '' };
    },
    logFn: () => {},
    maxRetries: Number(scenario.broker?.maxRetries ?? 1),
    allowProcessKill: scenario.broker?.allowProcessKill !== false,
    retryDelayMs: 0
  };

  return {
    healthDeps,
    brokerOptions,
    commandInvocations: () => commandInvocations,
    removedLocks: () => [...removedLocks],
    killedPids: () => [...killedPids],
    evaluateHealth: () =>
      evaluateWorkspaceHealth(
        {
          repoRoot,
          gitDir,
          leaseMode: 'ignore',
          lockStaleSeconds: Number(scenario.lockStaleSeconds ?? 30)
        },
        healthDeps
      )
  };
}

test('safe git chaos fixture contract is stable', () => {
  assert.equal(fixture.schema, 'priority/safe-git-chaos-scenarios@v1');
  assert.ok(Array.isArray(fixture.scenarios));
  assert.ok(fixture.scenarios.length >= 4);
});

for (const scenario of fixture.scenarios ?? []) {
  test(`safe-git chaos regression: ${scenario.id}`, () => {
    const state = createScenarioState(scenario);

    const preHealth = state.evaluateHealth();
    assert.equal(preHealth.status, 'fail');
    for (const expectedFailureId of scenario.health?.expectedFailureIds ?? []) {
      assert.ok(
        preHealth.failures.some((entry) => entry.id === expectedFailureId),
        `expected pre-health failure '${expectedFailureId}'`
      );
    }

    const brokerCommand = Array.isArray(scenario.command) ? scenario.command : ['push', 'origin', 'feature/x'];
    if (scenario.broker?.expect === 'throw') {
      assert.throws(
        () => runGitWithSafety(brokerCommand, { cwd: repoRoot, env: {} }, state.brokerOptions),
        new RegExp(String(scenario.broker?.errorPattern ?? 'blocked'), 'i')
      );
    } else {
      const result = runGitWithSafety(brokerCommand, { cwd: repoRoot, env: {} }, state.brokerOptions);
      assert.equal(result.status, 0);
    }

    assert.equal(
      state.commandInvocations(),
      Number(scenario.broker?.expectedCommandInvocations ?? 0),
      'unexpected mutating command invocation count'
    );

    assert.deepEqual(
      state.removedLocks().sort(),
      [...(scenario.broker?.expectedRemovedLocks ?? [])].sort(),
      'removed lock set mismatch'
    );
    assert.deepEqual(
      state.killedPids().sort((left, right) => left - right),
      [...(scenario.broker?.expectedKilledPids ?? [])].sort((left, right) => left - right),
      'killed pid set mismatch'
    );

    const postHealth = state.evaluateHealth();
    assert.equal(
      postHealth.status,
      scenario.health?.expectedPostStatus ?? 'fail',
      'unexpected post-health status'
    );
  });
}
