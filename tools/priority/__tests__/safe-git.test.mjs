#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { isMutatingGitCommand, runGitWithSafety } from '../lib/safe-git.mjs';

const repoRoot = path.join(path.sep, 'tmp', 'safe-git-repo');
const gitDir = path.join(repoRoot, '.git');
const indexLock = path.join(gitDir, 'index.lock');
const mergeHead = path.join(gitDir, 'MERGE_HEAD');

function makeCommonBroker(overrides = {}) {
  return {
    resolveGitDirFn: () => gitDir,
    readdirSyncFn: () => [],
    statSyncFn: () => ({ mtimeMs: 0 }),
    rmSyncFn: () => {},
    listGitProcessesFn: () => [],
    logFn: () => {},
    nowFn: () => 1_000_000,
    retryDelayMs: 0,
    ...overrides
  };
}

test('isMutatingGitCommand classifies mutating and non-mutating commands', () => {
  assert.equal(isMutatingGitCommand(['push', 'origin', 'feature/x']), true);
  assert.equal(isMutatingGitCommand(['commit', '-m', 'msg']), true);
  assert.equal(isMutatingGitCommand(['branch', '-m', 'old', 'new']), true);
  assert.equal(isMutatingGitCommand(['tag', 'v1.2.3']), true);

  assert.equal(isMutatingGitCommand(['status']), false);
  assert.equal(isMutatingGitCommand(['rev-parse', 'HEAD']), false);
  assert.equal(isMutatingGitCommand(['branch', '--list']), false);
  assert.equal(isMutatingGitCommand(['tag', '--list']), false);
});

test('runGitWithSafety fails fast when merge state is in progress', () => {
  assert.throws(
    () =>
      runGitWithSafety(
        ['push', 'origin', 'feature/x'],
        { cwd: repoRoot, env: {} },
        makeCommonBroker({
          existsSyncFn: (target) => target === mergeHead,
          spawnSyncFn: () => {
            throw new Error('git command should not execute when merge state is blocked');
          }
        })
      ),
    /merge in progress/i
  );
});

test('runGitWithSafety removes stale lock and executes command', () => {
  let lockExists = true;
  const removed = [];
  let invocationCount = 0;

  const result = runGitWithSafety(
    ['push', 'origin', 'feature/x'],
    { cwd: repoRoot, env: {} },
    makeCommonBroker({
      existsSyncFn: (target) => target === indexLock && lockExists,
      rmSyncFn: (target) => {
        removed.push(target);
        lockExists = false;
      },
      spawnSyncFn: () => {
        invocationCount += 1;
        return { status: 0, stdout: 'ok', stderr: '' };
      }
    })
  );

  assert.equal(result.status, 0);
  assert.equal(invocationCount, 1);
  assert.deepEqual(removed, [indexLock]);
});

test('runGitWithSafety retries once after runtime lock conflict', () => {
  let lockExists = false;
  let callCount = 0;
  let removedCount = 0;

  const result = runGitWithSafety(
    ['push', 'origin', 'feature/x'],
    { cwd: repoRoot, env: {} },
    makeCommonBroker({
      maxRetries: 1,
      existsSyncFn: (target) => target === indexLock && lockExists,
      rmSyncFn: () => {
        lockExists = false;
        removedCount += 1;
      },
      spawnSyncFn: () => {
        callCount += 1;
        if (callCount === 1) {
          lockExists = true;
          return {
            status: 128,
            stdout: '',
            stderr: "fatal: Unable to create '.git/index.lock': File exists."
          };
        }
        return { status: 0, stdout: 'ok', stderr: '' };
      }
    })
  );

  assert.equal(result.status, 0);
  assert.equal(callCount, 2);
  assert.equal(removedCount, 1);
});

test('runGitWithSafety fails with bounded guidance when active lock cannot be repaired', () => {
  let commandInvoked = false;

  assert.throws(
    () =>
      runGitWithSafety(
        ['push', 'origin', 'feature/x'],
        { cwd: repoRoot, env: {} },
        makeCommonBroker({
          maxRetries: 1,
          staleLockAgeMs: 60_000,
          allowProcessKill: false,
          nowFn: () => 100_000,
          existsSyncFn: (target) => target === indexLock,
          statSyncFn: () => ({ mtimeMs: 99_500 }),
          listGitProcessesFn: () => [4567],
          spawnSyncFn: () => {
            commandInvoked = true;
            return { status: 0, stdout: '', stderr: '' };
          }
        })
      ),
    /Auto-repair is bounded/i
  );

  assert.equal(commandInvoked, false);
});

test('runGitWithSafety kills stale git process when allowed and proceeds', () => {
  let lockExists = true;
  let activePids = [999];
  const killed = [];
  const removed = [];

  const result = runGitWithSafety(
    ['push', 'origin', 'feature/x'],
    { cwd: repoRoot, env: {} },
    makeCommonBroker({
      allowProcessKill: true,
      staleLockAgeMs: 1_000,
      nowFn: () => 50_000,
      existsSyncFn: (target) => target === indexLock && lockExists,
      statSyncFn: () => ({ mtimeMs: 0 }),
      listGitProcessesFn: () => activePids,
      killGitProcessFn: (pid) => {
        killed.push(pid);
        activePids = [];
        return true;
      },
      rmSyncFn: (target) => {
        removed.push(target);
        lockExists = false;
      },
      spawnSyncFn: () => ({ status: 0, stdout: 'ok', stderr: '' })
    })
  );

  assert.equal(result.status, 0);
  assert.deepEqual(killed, [999]);
  assert.deepEqual(removed, [indexLock]);
});

test('runGitWithSafety emits deterministic telemetry for repair flow', () => {
  let lockExists = true;
  const writes = [];
  let nowMs = 10_000;

  const result = runGitWithSafety(
    ['push', 'origin', 'feature/x'],
    { cwd: repoRoot, env: {} },
    makeCommonBroker({
      telemetryPath: path.join(repoRoot, 'tests', 'results', '_agent', 'reliability', 'safe-git-events.jsonl'),
      nowFn: () => {
        nowMs += 50;
        return nowMs;
      },
      existsSyncFn: (target) => target === indexLock && lockExists,
      rmSyncFn: () => {
        lockExists = false;
      },
      spawnSyncFn: () => ({ status: 0, stdout: 'ok', stderr: '' }),
      mkdirSyncFn: () => {},
      appendFileSyncFn: (_targetPath, payload) => {
        writes.push(String(payload));
      }
    })
  );

  assert.equal(result.status, 0);
  assert.equal(writes.length, 1);

  const telemetry = JSON.parse(writes[0].trim());
  assert.equal(telemetry.schema, 'priority/safe-git-run-telemetry@v1');
  assert.equal(telemetry.status, 'success');
  assert.equal(telemetry.reason, 'ok');
  assert.equal(telemetry.counters.lockDetections, 1);
  assert.equal(telemetry.counters.repairAttempts, 1);
  assert.equal(telemetry.counters.repairSuccesses, 1);
  assert.ok(Array.isArray(telemetry.events));
  assert.ok(telemetry.events.some((event) => event.type === 'lock-detected'));
  assert.ok(telemetry.events.some((event) => event.type === 'repair-attempt'));
  assert.ok(telemetry.events.some((event) => event.type === 'repair-result' && event.outcome === 'success'));
});
